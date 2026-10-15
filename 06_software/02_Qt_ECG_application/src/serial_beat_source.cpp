#include "serial_beat_source.h"

#include <QDebug>
#include <QSocketNotifier>
#include <QStringList>

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <termios.h>
#include <unistd.h>

SerialBeatSource::SerialBeatSource(QObject *parent) : QObject(parent) {}

SerialBeatSource::~SerialBeatSource() { close(); }

QStringList SerialBeatSource::defaultPortCandidates()
{
    // CP2102 cua ESP32 hien ra la ttyUSB0. Cac ten con lai de phong board dung
    // module khac (CH340 van la ttyUSB, ESP32-S3 native USB la ttyACM).
    return {"/dev/ttyUSB0", "/dev/ttyUSB1", "/dev/ttyACM0", "/dev/ttyACM1"};
}

bool SerialBeatSource::open(const QString &portPath, QString *errorMessage)
{
    close();

    const QByteArray path = portPath.toLocal8Bit();
    // O_NONBLOCK khi mo la bat buoc: neu khong, open() se cho tin hieu DCD tren
    // mot so driver va treo ca GUI.
    fd_ = ::open(path.constData(), O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd_ < 0)
    {
        if (errorMessage)
        {
            *errorMessage = QString("khong mo duoc %1: %2")
                                .arg(portPath, QString::fromLocal8Bit(strerror(errno)));
        }
        return false;
    }

    termios tty{};
    if (tcgetattr(fd_, &tty) != 0)
    {
        if (errorMessage)
        {
            *errorMessage = QString("tcgetattr that bai tren %1: %2")
                                .arg(portPath, QString::fromLocal8Bit(strerror(errno)));
        }
        ::close(fd_);
        fd_ = -1;
        return false;
    }

    cfmakeraw(&tty);
    cfsetispeed(&tty, B115200);
    cfsetospeed(&tty, B115200);
    tty.c_cflag |= (CLOCAL | CREAD);     // bo qua tin hieu modem, bat nhan
    tty.c_cflag &= ~CRTSCTS;             // ESP32 khong dung bat tay phan cung
    tty.c_cflag &= ~CSTOPB;              // 1 stop bit
    tty.c_cflag &= ~PARENB;              // khong parity
    tty.c_cc[VMIN] = 0;
    tty.c_cc[VTIME] = 0;

    if (tcsetattr(fd_, TCSANOW, &tty) != 0)
    {
        if (errorMessage)
        {
            *errorMessage = QString("tcsetattr that bai tren %1: %2")
                                .arg(portPath, QString::fromLocal8Bit(strerror(errno)));
        }
        ::close(fd_);
        fd_ = -1;
        return false;
    }

    tcflush(fd_, TCIOFLUSH);
    portPath_ = portPath;
    buffer_.clear();

    qInfo().noquote() << QString("[SERIAL] mo %1 thanh cong (fd=%2)").arg(portPath).arg(fd_);
    notifier_ = new QSocketNotifier(fd_, QSocketNotifier::Read, this);
    connect(notifier_, &QSocketNotifier::activated, this, &SerialBeatSource::onReadable);
    notifier_->setEnabled(true);
    return true;
}

void SerialBeatSource::close()
{
    if (notifier_)
    {
        notifier_->setEnabled(false);
        notifier_->deleteLater();
        notifier_ = nullptr;
    }
    if (fd_ >= 0)
    {
        ::close(fd_);
        fd_ = -1;
    }
    buffer_.clear();
    portPath_.clear();
}

void SerialBeatSource::onReadable()
{
    char chunk[4096];
    for (;;)
    {
        const ssize_t got = ::read(fd_, chunk, sizeof chunk);
        if (got > 0)
        {
            buffer_.append(chunk, static_cast<int>(got));
            continue;
        }
        if (got == 0) break;
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        if (errno == EINTR) continue;

        const QString reason = QString::fromLocal8Bit(strerror(errno));
        close();
        emit disconnected(reason);
        return;
    }

    // Mot khung day du la 187 so cong phan dau, khoang 900 byte, nen no gan nhu
    // luon den lam nhieu manh. Chi xu ly khi da co dau xuong dong.
    int newline;
    while ((newline = buffer_.indexOf('\n')) >= 0)
    {
        QByteArray line = buffer_.left(newline);
        buffer_.remove(0, newline + 1);
        if (line.endsWith('\r')) line.chop(1);
        if (!line.isEmpty())
        {
            if (!sawAnyLine_)
            {
                sawAnyLine_ = true;
                qInfo().noquote() << QString("[SERIAL] dong dau tien (%1 byte): %2")
                                         .arg(line.size())
                                         .arg(QString::fromLatin1(line.left(60)));
            }
            parseLine(line);
        }
    }

    // Chan bo dem phinh vo han neu gap thiet bi noi rac khong co xuong dong.
    if (buffer_.size() > 64 * 1024) buffer_.clear();
}

void SerialBeatSource::parseLine(const QByteArray &line)
{
    if (line.startsWith('#'))
    {
        emit statusLine(QString::fromLatin1(line.mid(1).trimmed()));
        return;
    }
    if (!line.startsWith("B,")) return;

    const QList<QByteArray> fields = line.split(',');
    // B , seq , class , bpm , 187 mau
    if (fields.size() != 4 + kSamplesPerBeat) return;

    bool ok = false;
    const int classIndex = fields.at(2).toInt(&ok);
    if (!ok || classIndex < 0 || classIndex > 4) return;
    const double bpm = fields.at(3).toDouble(&ok);
    if (!ok) return;

    QVector<qint16> samples;
    samples.reserve(kSamplesPerBeat);
    for (int i = 0; i < kSamplesPerBeat; ++i)
    {
        const int value = fields.at(4 + i).toInt(&ok);
        // Mot khung hong bi bo nguyen ven chu khong dung mot phan: nhip nua voi
        // se lang le lam sai ket qua phan loai.
        if (!ok || value < -32768 || value > 32767) return;
        samples.append(static_cast<qint16>(value));
    }

    emit beatReceived(classIndex, bpm, samples);
}

void SerialBeatSource::sendLine(const QByteArray &line)
{
    if (fd_ < 0) return;
    QByteArray payload = line;
    payload.append('\n');
    ssize_t written = 0;
    while (written < payload.size())
    {
        const ssize_t got = ::write(fd_, payload.constData() + written,
                                    static_cast<size_t>(payload.size() - written));
        if (got > 0) { written += got; continue; }
        if (got < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) continue;
        break;
    }
}

void SerialBeatSource::sendClass(int classIndex)
{
    if (classIndex < 0 || classIndex > 4) return;
    sendLine(QByteArray::number(classIndex));
}

void SerialBeatSource::sendBpm(double bpm)
{
    sendLine("BPM " + QByteArray::number(bpm, 'f', 1));
}

void SerialBeatSource::sendStart() { sendLine("START"); }
void SerialBeatSource::sendStop() { sendLine("STOP"); }
void SerialBeatSource::sendStatusQuery() { sendLine("STATUS"); }
