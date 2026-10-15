#pragma once

#include <QVector>

class SignalBuffer
{
public:
    static constexpr int kSampleRate = 125;
    static constexpr int kVisibleSamples = 1250;
    static constexpr int kMaxFullSamples = kSampleRate * 60 * 10; // 10 minutes

    SignalBuffer();
    void clear();
    void append(const QVector<double> &raw, const QVector<double> &processed);

    qint64 totalSamples() const;
    int cursor() const;
    bool filled() const;

    QVector<double> sweepValues(bool processed, int gapSamples = 10) const;
    QVector<double> sweepKeys() const;
    QVector<double> scrollingValues(bool processed) const;
    QVector<double> scrollingKeys() const;
    QVector<double> fullValues(bool processed) const;
    QVector<double> fullKeys() const;

    bool extractRange(qint64 startSample,
                      qint64 endSample,
                      QVector<double> *raw,
                      QVector<double> *processed) const;

    bool exportVisibleCsv(const QString &path, QString *errorMessage = nullptr) const;

private:
    QVector<double> chronologicalVisible(const QVector<double> &buffer) const;

    QVector<double> rawSweep_;
    QVector<double> processedSweep_;
    QVector<double> fullRaw_;
    QVector<double> fullProcessed_;
    int cursor_ = 0;
    bool filled_ = false;
    qint64 totalSamples_ = 0;
};
