#pragma once

#include <QByteArray>
#include <QObject>
#include <QString>
#include <QVector>
#include <QtGlobal>

class QSocketNotifier;

// Nguon nhip lay tu ESP32 qua USB serial.
//
// Khong dung QtSerialPort: goi do khong co san tren board, con cong serial tren
// Linux chi la mot file. Mo bang termios roi theo doi bang QSocketNotifier thi
// tich hop thang vao vong su kien Qt, khong can luong rieng va khong them phu
// thuoc nao.
//
// Khung ESP32 gui (ASCII, moi nhip mot dong):
//     B,<seq>,<class>,<bpm>,q0,q1,...,q186
// q0..q186 la Q8.8 co dau. Dong bat dau bang '#' la thong bao trang thai.
class SerialBeatSource final : public QObject
{
    Q_OBJECT

public:
    static constexpr int kSamplesPerBeat = 187;

    explicit SerialBeatSource(QObject *parent = nullptr);
    ~SerialBeatSource() override;

    // Mo cong. Tra ve false kem ly do neu that bai; goi ham nay khong bao gio
    // nem ngoai le, de ben goi co the lang le quay ve nguon du phong.
    bool open(const QString &portPath, QString *errorMessage = nullptr);
    void close();
    bool isOpen() const { return fd_ >= 0; }
    QString portPath() const { return portPath_; }

    // Cac lenh gui sang ESP32. Deu khong lam gi neu cong chua mo.
    void sendClass(int classIndex);
    void sendBpm(double bpm);
    void sendStart();
    void sendStop();
    void sendStatusQuery();

    // Duong dan mac dinh, thu lan luot cho den khi mo duoc.
    static QStringList defaultPortCandidates();

signals:
    void beatReceived(int classIndex, double bpm, const QVector<qint16> &samples);
    void statusLine(const QString &text);
    void disconnected(const QString &reason);

private slots:
    void onReadable();

private:
    void sendLine(const QByteArray &line);
    void parseLine(const QByteArray &line);

    int fd_ = -1;
    QSocketNotifier *notifier_ = nullptr;
    QByteArray buffer_;
    QString portPath_;
    bool sawAnyLine_ = false;
};
