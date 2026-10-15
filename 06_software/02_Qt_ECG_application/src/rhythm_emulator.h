#pragma once

#include "ecg_types.h"
#include "fixed_beat_library.h"

#include <QVector>

#include <random>

class RhythmEmulator
{
public:
    static constexpr int kSampleRate = 125;
    static constexpr int kDisplaySeconds = 10;
    static constexpr int kDisplaySamples = kSampleRate * kDisplaySeconds;

    explicit RhythmEmulator(const FixedBeatLibrary *library = nullptr);

    void setLibrary(const FixedBeatLibrary *library);
    void setMode(int classIndex);
    int mode() const;
    void setBpm(double bpm);
    double bpm() const;
    void setNoise(double relativeMv);
    double noise() const;
    void setBaselineWander(double relativeMv);

    // Nhip that nhan tu nguon ngoai (ESP32). Khi mot lop da co nhip ngoai, no
    // duoc dung thay cho nhip nap tu data/, nen data/ chi con la ban du phong
    // luc khoi dong hoac khi khong co thiet bi.
    void setExternalBeat(int classIndex, const FixedBeat &beat);
    void clearExternalBeats();
    bool hasExternalBeat(int classIndex) const;
    const FixedBeat &externalBeat(int classIndex) const;

    void reset();

    SignalBlock nextSamples(int count);
    qint64 generatedSamples() const;

private:
    struct ActiveBeat
    {
        qint64 rSample = 0;
        int classIndex = 0;
    };

    struct PatternStep
    {
        int classIndex;
        double rrFactor;
    };

    QVector<PatternStep> pattern() const;
    // Nhip dung de dung dang song: uu tien nguon ngoai, roi moi den thu vien.
    const FixedBeat &beatFor(int classIndex) const;

    QVector<FixedBeat> externalBeats_;
    QVector<bool> hasExternal_;
    void scheduleUntil(qint64 absoluteLimit, QVector<BeatEvent> *newEvents, qint64 blockStart, qint64 blockStop);

    const FixedBeatLibrary *library_ = nullptr;
    int mode_ = 0;
    double bpm_ = 72.0;
    double noise_ = 0.003;
    double baselineWander_ = 0.004;
    qint64 sampleIndex_ = 0;
    int patternIndex_ = 0;
    double nextRsample_ = 0.0;
    QVector<ActiveBeat> activeBeats_;
    std::mt19937 rng_;
    std::normal_distribution<double> standardNormal_{0.0, 1.0};
};
