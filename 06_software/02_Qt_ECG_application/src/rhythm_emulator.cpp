#include "rhythm_emulator.h"

#include <algorithm>
#include <cmath>

namespace
{
constexpr double kDefaultBpm[5] = {72.0, 76.0, 72.0, 72.0, 74.0};
constexpr double kPi = 3.14159265358979323846;
}

RhythmEmulator::RhythmEmulator(const FixedBeatLibrary *library)
    : library_(library), rng_(20260922U)
{
    externalBeats_.resize(FixedBeatLibrary::kClassCount);
    hasExternal_.fill(false, FixedBeatLibrary::kClassCount);
    reset();
}

void RhythmEmulator::setExternalBeat(const int classIndex, const FixedBeat &beat)
{
    if (classIndex < 0 || classIndex >= externalBeats_.size()) return;
    // Mot khung hong cho ra displayWave rong; giu lai nhip cu con hon la lam
    // dang song bien mat giua chung.
    if (beat.displayWave.isEmpty()) return;
    externalBeats_[classIndex] = beat;
    hasExternal_[classIndex] = true;
}

void RhythmEmulator::clearExternalBeats()
{
    hasExternal_.fill(false, FixedBeatLibrary::kClassCount);
}

bool RhythmEmulator::hasExternalBeat(const int classIndex) const
{
    return classIndex >= 0 && classIndex < hasExternal_.size() && hasExternal_[classIndex];
}

const FixedBeat &RhythmEmulator::externalBeat(const int classIndex) const
{
    static const FixedBeat empty;
    return hasExternalBeat(classIndex) ? externalBeats_[classIndex] : empty;
}

const FixedBeat &RhythmEmulator::beatFor(const int classIndex) const
{
    if (classIndex >= 0 && classIndex < hasExternal_.size() && hasExternal_[classIndex])
    {
        return externalBeats_[classIndex];
    }
    static const FixedBeat empty;
    return library_ != nullptr ? library_->beat(classIndex) : empty;
}

void RhythmEmulator::setLibrary(const FixedBeatLibrary *library)
{
    library_ = library;
    reset();
}

void RhythmEmulator::setMode(const int classIndex)
{
    mode_ = std::clamp(classIndex, 0, 4);
    bpm_ = kDefaultBpm[mode_];
    rng_.seed(20260922U + static_cast<unsigned>(mode_) * 1009U);
    reset();
}

int RhythmEmulator::mode() const { return mode_; }

void RhythmEmulator::setBpm(const double bpm)
{
    bpm_ = std::clamp(bpm, 40.0, 160.0);
}

double RhythmEmulator::bpm() const { return bpm_; }

void RhythmEmulator::setNoise(const double relativeMv)
{
    noise_ = std::clamp(relativeMv, 0.0, 0.05);
}

double RhythmEmulator::noise() const { return noise_; }

void RhythmEmulator::setBaselineWander(const double relativeMv)
{
    baselineWander_ = std::clamp(relativeMv, 0.0, 0.05);
}

void RhythmEmulator::reset()
{
    sampleIndex_ = 0;
    patternIndex_ = 0;
    nextRsample_ = std::round(0.60 * static_cast<double>(kSampleRate));
    activeBeats_.clear();
}

QVector<RhythmEmulator::PatternStep> RhythmEmulator::pattern() const
{
    switch (mode_)
    {
    case 1:
        return {{0, 1.00}, {0, 0.70}, {1, 0.84}, {0, 1.00}, {0, 1.00}};
    case 2:
        return {{0, 1.00}, {0, 0.72}, {2, 1.28}, {0, 1.00}, {0, 1.00}};
    case 3:
        return {{0, 1.00}, {0, 0.78}, {3, 1.15}, {0, 1.00}, {0, 1.00}};
    case 4:
        return {{0, 1.00}, {4, 1.00}, {0, 1.00}, {0, 1.00}, {4, 1.00}};
    default:
        return {{0, 1.00}, {0, 1.00}, {0, 1.00}, {0, 1.00}};
    }
}

void RhythmEmulator::scheduleUntil(const qint64 absoluteLimit,
                                   QVector<BeatEvent> *newEvents,
                                   const qint64 blockStart,
                                   const qint64 blockStop)
{
    const QVector<PatternStep> steps = pattern();
    while (static_cast<qint64>(std::llround(nextRsample_)) <= absoluteLimit)
    {
        const PatternStep step = steps[patternIndex_ % steps.size()];
        const qint64 rSample = static_cast<qint64>(std::llround(nextRsample_));
        activeBeats_.append({rSample, step.classIndex});
        if (newEvents != nullptr && rSample >= blockStart && rSample < blockStop)
        {
            newEvents->append({rSample, step.classIndex});
        }

        const double baseRr = static_cast<double>(kSampleRate) * 60.0 / bpm_;
        const double jitter = standardNormal_(rng_) * 0.006;
        const double rr = std::max(static_cast<double>(kSampleRate) * 0.30,
                                   baseRr * step.rrFactor * (1.0 + jitter));
        nextRsample_ += rr;
        ++patternIndex_;
    }
}

SignalBlock RhythmEmulator::nextSamples(const int count)
{
    SignalBlock block;
    if (count <= 0 || library_ == nullptr || !library_->isLoaded())
    {
        return block;
    }

    const qint64 blockStart = sampleIndex_;
    const qint64 blockStop = blockStart + count;
    scheduleUntil(blockStop - 1,
                  &block.events,
                  blockStart,
                  blockStop);

    block.raw.fill(0.0, count);
    QVector<ActiveBeat> keep;

    for (const ActiveBeat &event : activeBeats_)
    {
        const QVector<double> &wave = beatFor(event.classIndex).displayWave;
        const qint64 waveStart = event.rSample;
        const qint64 waveStop = waveStart + wave.size();

        if (waveStop <= blockStart)
        {
            continue;
        }
        if (waveStart >= blockStop)
        {
            keep.append(event);
            continue;
        }

        const qint64 overlapStart = std::max(blockStart, waveStart);
        const qint64 overlapStop = std::min(blockStop, waveStop);
        for (qint64 absolute = overlapStart; absolute < overlapStop; ++absolute)
        {
            const int source = static_cast<int>(absolute - waveStart);
            const int destination = static_cast<int>(absolute - blockStart);
            block.raw[destination] += wave[source];
        }

        if (waveStop > blockStop)
        {
            keep.append(event);
        }
    }

    for (const ActiveBeat &event : activeBeats_)
    {
        if (event.rSample >= blockStop)
        {
            bool exists = false;
            for (const ActiveBeat &candidate : keep)
            {
                if (candidate.rSample == event.rSample && candidate.classIndex == event.classIndex)
                {
                    exists = true;
                    break;
                }
            }
            if (!exists)
            {
                keep.append(event);
            }
        }
    }
    activeBeats_ = keep;

    for (int i = 0; i < block.raw.size(); ++i)
    {
        const qint64 absolute = blockStart + i;
        const double t = static_cast<double>(absolute) / static_cast<double>(kSampleRate);
        double value = block.raw[i];
        value += baselineWander_ * std::sin(2.0 * kPi * 0.20 * t);
        value += 0.25 * baselineWander_ * std::sin(2.0 * kPi * 0.07 * t + 0.8);
        value += standardNormal_(rng_) * noise_;
        block.raw[i] = std::clamp(value, -2.5, 2.5);
    }

    sampleIndex_ = blockStop;
    return block;
}

qint64 RhythmEmulator::generatedSamples() const
{
    return sampleIndex_;
}
