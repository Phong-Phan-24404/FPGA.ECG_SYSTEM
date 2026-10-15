#include "ai/beat_preprocessor.h"

namespace BeatPreprocessor
{
bool validateQ88Beat187(const QVector<qint16> &beat)
{
    if (beat.size() != kModelInputSamples)
    {
        return false;
    }
    // Integers cannot be NaN or infinite, so unlike the float version this only
    // has to check the range the dataset is defined over.
    for (const qint16 raw : beat)
    {
        if (raw < kMinRaw || raw > kMaxRaw)
        {
            return false;
        }
    }
    return true;
}

float toFloat(const qint16 raw)
{
    return static_cast<float>(raw) / kScale;
}

QVector<float> toFloat(const QVector<qint16> &beat)
{
    QVector<float> out;
    out.reserve(beat.size());
    for (const qint16 raw : beat)
    {
        out.append(toFloat(raw));
    }
    return out;
}
}
