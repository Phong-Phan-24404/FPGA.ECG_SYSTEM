#include "signal_buffer.h"

#include <QFile>
#include <QTextStream>

#include <algorithm>
#include <cmath>
#include <limits>

SignalBuffer::SignalBuffer()
{
    clear();
}

void SignalBuffer::clear()
{
    rawSweep_.fill(0.0, kVisibleSamples);
    processedSweep_.fill(0.0, kVisibleSamples);
    fullRaw_.clear();
    fullProcessed_.clear();
    cursor_ = 0;
    filled_ = false;
    totalSamples_ = 0;
}

void SignalBuffer::append(const QVector<double> &raw, const QVector<double> &processed)
{
    const int count = std::min(static_cast<int>(raw.size()), static_cast<int>(processed.size()));
    for (int i = 0; i < count; ++i)
    {
        rawSweep_[cursor_] = raw[i];
        processedSweep_[cursor_] = processed[i];
        cursor_ = (cursor_ + 1) % kVisibleSamples;
        if (!filled_ && totalSamples_ + i + 1 >= kVisibleSamples)
        {
            filled_ = true;
        }
        fullRaw_.append(raw[i]);
        fullProcessed_.append(processed[i]);
    }
    totalSamples_ += count;

    if (static_cast<int>(fullRaw_.size()) > kMaxFullSamples)
    {
        const int removeCount = static_cast<int>(fullRaw_.size()) - kMaxFullSamples;
        fullRaw_.remove(0, removeCount);
        fullProcessed_.remove(0, removeCount);
    }
}

qint64 SignalBuffer::totalSamples() const { return totalSamples_; }
int SignalBuffer::cursor() const { return cursor_; }
bool SignalBuffer::filled() const { return filled_; }

QVector<double> SignalBuffer::sweepKeys() const
{
    QVector<double> keys(kVisibleSamples);
    for (int i = 0; i < kVisibleSamples; ++i)
    {
        keys[i] = static_cast<double>(i) / kSampleRate;
    }
    return keys;
}

QVector<double> SignalBuffer::sweepValues(const bool processed, const int gapSamples) const
{
    QVector<double> values = processed ? processedSweep_ : rawSweep_;
    const int gap = std::max(1, gapSamples);
    if (!filled_)
    {
        for (int i = std::max(0, cursor_ - gap); i < kVisibleSamples; ++i)
        {
            values[i] = std::numeric_limits<double>::quiet_NaN();
        }
    }
    else
    {
        for (int offset = -gap; offset <= gap; ++offset)
        {
            int index = (cursor_ + offset) % kVisibleSamples;
            if (index < 0)
            {
                index += kVisibleSamples;
            }
            values[index] = std::numeric_limits<double>::quiet_NaN();
        }
    }
    return values;
}

QVector<double> SignalBuffer::chronologicalVisible(const QVector<double> &buffer) const
{
    if (!filled_)
    {
        return buffer.mid(0, cursor_);
    }
    QVector<double> result;
    result.reserve(kVisibleSamples);
    for (int i = cursor_; i < kVisibleSamples; ++i)
    {
        result.append(buffer[i]);
    }
    for (int i = 0; i < cursor_; ++i)
    {
        result.append(buffer[i]);
    }
    return result;
}

QVector<double> SignalBuffer::scrollingValues(const bool processed) const
{
    return chronologicalVisible(processed ? processedSweep_ : rawSweep_);
}

QVector<double> SignalBuffer::scrollingKeys() const
{
    const int count = filled_ ? kVisibleSamples : cursor_;
    QVector<double> keys;
    keys.reserve(count);
    const qint64 firstSample = std::max<qint64>(0, totalSamples_ - count);
    for (int i = 0; i < count; ++i)
    {
        keys.append(static_cast<double>(firstSample + i) / kSampleRate);
    }
    return keys;
}

QVector<double> SignalBuffer::fullValues(const bool processed) const
{
    return processed ? fullProcessed_ : fullRaw_;
}

QVector<double> SignalBuffer::fullKeys() const
{
    QVector<double> keys;
    keys.reserve(fullRaw_.size());
    const qint64 firstSample = std::max<qint64>(0, totalSamples_ - fullRaw_.size());
    for (int i = 0; i < fullRaw_.size(); ++i)
    {
        keys.append(static_cast<double>(firstSample + i) / kSampleRate);
    }
    return keys;
}

bool SignalBuffer::extractRange(const qint64 startSample,
                                const qint64 endSample,
                                QVector<double> *raw,
                                QVector<double> *processed) const
{
    if (raw == nullptr || processed == nullptr || startSample < 0 || endSample <= startSample)
    {
        return false;
    }

    const qint64 retainedStart = totalSamples_ - static_cast<qint64>(fullRaw_.size());
    if (startSample < retainedStart || endSample > totalSamples_)
    {
        return false;
    }

    const qint64 offset64 = startSample - retainedStart;
    const qint64 length64 = endSample - startSample;
    if (offset64 < 0 || length64 <= 0 ||
        offset64 + length64 > static_cast<qint64>(fullRaw_.size()))
    {
        return false;
    }

    const int offset = static_cast<int>(offset64);
    const int length = static_cast<int>(length64);
    *raw = fullRaw_.mid(offset, length);
    *processed = fullProcessed_.mid(offset, length);
    return raw->size() == length && processed->size() == length;
}

bool SignalBuffer::exportVisibleCsv(const QString &path, QString *errorMessage) const
{
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text | QIODevice::Truncate))
    {
        if (errorMessage != nullptr)
        {
            *errorMessage = QString("Cannot write %1").arg(path);
        }
        return false;
    }

    const QVector<double> raw = chronologicalVisible(rawSweep_);
    const QVector<double> processed = chronologicalVisible(processedSweep_);
    const int count = std::min(static_cast<int>(raw.size()), static_cast<int>(processed.size()));
    const qint64 firstSample = std::max<qint64>(0, totalSamples_ - count);

    QTextStream stream(&file);
    stream << "time_s,raw_relative_mv,processed_relative_mv\n";
    for (int i = 0; i < count; ++i)
    {
        stream << QString::number(static_cast<double>(firstSample + i) / kSampleRate, 'f', 6) << ','
               << QString::number(raw[i], 'f', 7) << ','
               << QString::number(processed[i], 'f', 7) << '\n';
    }
    return true;
}
