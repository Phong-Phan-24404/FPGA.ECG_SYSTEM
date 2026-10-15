#include "fixed_beat_library.h"

#include "ecg_types.h"
#include "ai/beat_preprocessor.h"

#include <QFile>
#include <QFileInfo>
#include <QTextStream>

#include <algorithm>
#include <cmath>
#include <limits>

namespace
{
constexpr const char *kFiles[FixedBeatLibrary::kClassCount] = {
    "sampleN.txt", "sampleS.txt", "sampleV.txt", "sampleF.txt", "sampleQ.txt"};
constexpr double kTargetQrs[FixedBeatLibrary::kClassCount] = {1.00, 0.95, 1.15, 1.05, 0.90};
constexpr int kQrsGuardSamples = 10;
constexpr int kEdgeTaperSamples = 8;

double medianOf(QVector<double> values)
{
    if (values.isEmpty())
    {
        return 0.0;
    }
    std::sort(values.begin(), values.end());
    const int n = values.size();
    return n % 2 == 0 ? 0.5 * (values[n / 2 - 1] + values[n / 2]) : values[n / 2];
}
}

bool FixedBeatLibrary::load(const QString &dataDirectory, QString *errorMessage)
{
    beats_.clear();
    loaded_ = false;
    maxDisplayTemplateLength_ = 0;

    for (int classIndex = 0; classIndex < kClassCount; ++classIndex)
    {
        FixedBeat beat;
        const QString path = dataDirectory + "/" + QString::fromLatin1(kFiles[classIndex]);
        if (!loadOne(classIndex, path, &beat, errorMessage))
        {
            return false;
        }
        maxDisplayTemplateLength_ = std::max(maxDisplayTemplateLength_, static_cast<int>(beat.displayWave.size()));
        beats_.append(beat);
    }

    loaded_ = true;
    return true;
}

bool FixedBeatLibrary::isLoaded() const
{
    return loaded_;
}

const FixedBeat &FixedBeatLibrary::beat(const int classIndex) const
{
    static const FixedBeat empty;
    return classIndex >= 0 && classIndex < beats_.size() ? beats_[classIndex] : empty;
}

int FixedBeatLibrary::maxDisplayTemplateLength() const
{
    return maxDisplayTemplateLength_;
}

QString FixedBeatLibrary::summary() const
{
    if (!loaded_)
    {
        return "Beat library not loaded";
    }
    return "ECG data ready";
}

bool FixedBeatLibrary::loadOne(const int classIndex,
                               const QString &path,
                               FixedBeat *out,
                               QString *errorMessage)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text))
    {
        if (errorMessage != nullptr)
        {
            *errorMessage = QString("Cannot open ECG sample: %1").arg(QFileInfo(path).absoluteFilePath());
        }
        return false;
    }

    QVector<double> values;
    QTextStream stream(&file);
    while (!stream.atEnd())
    {
        const QString line = stream.readLine().trimmed();
        if (line.isEmpty())
        {
            continue;
        }
        QString normalized = line;
        normalized.replace(',', ' ');
        normalized.replace(';', ' ');
        const QStringList tokens = normalized.simplified().split(' ', Qt::SkipEmptyParts);
        for (const QString &token : tokens)
        {
            bool ok = false;
            const double value = token.toDouble(&ok);
            if (!ok || !std::isfinite(value))
            {
                if (errorMessage != nullptr)
                {
                    *errorMessage = QString("Invalid numeric value in %1").arg(path);
                }
                return false;
            }
            values.append(value);
        }
    }

    if (values.size() != kModelInputSamples)
    {
        if (errorMessage != nullptr)
        {
            *errorMessage = QString("%1 contains %2 samples; exactly %3 are required.")
                                .arg(QFileInfo(path).fileName())
                                .arg(values.size())
                                .arg(kModelInputSamples);
        }
        return false;
    }

    // The samples are Q8.8 integers now, so the range check is in raw units:
    // the dataset is normalised to [0, 1], which is [0, 256] here.
    double minValue = std::numeric_limits<double>::infinity();
    double maxValue = -std::numeric_limits<double>::infinity();
    bool integral = true;
    for (const double value : values)
    {
        minValue = std::min(minValue, value);
        maxValue = std::max(maxValue, value);
        if (value != std::floor(value))
        {
            integral = false;
        }
    }

    // A file still in the old float format parses as a run of 0s and 1s, which
    // would otherwise pass every check below and silently produce a flat beat.
    if (!integral || maxValue <= 1.0)
    {
        if (errorMessage != nullptr)
        {
            *errorMessage =
                QString("%1 does not look like Q8.8 data (values must be integers "
                        "spanning up to %2). Regenerate it with "
                        "kv260_bringup/quantize/make_samples.py.")
                    .arg(QFileInfo(path).fileName())
                    .arg(BeatPreprocessor::kMaxRaw);
        }
        return false;
    }
    if (maxValue - minValue < 1.0)
    {
        if (errorMessage != nullptr)
        {
            *errorMessage = QString("%1 has no usable signal variation.").arg(QFileInfo(path).fileName());
        }
        return false;
    }
    if (minValue < BeatPreprocessor::kMinRaw || maxValue > BeatPreprocessor::kMaxRaw)
    {
        if (errorMessage != nullptr)
        {
            *errorMessage = QString("%1 is outside the expected Q8.8 range [%2, %3].")
                                .arg(QFileInfo(path).fileName())
                                .arg(BeatPreprocessor::kMinRaw)
                                .arg(BeatPreprocessor::kMaxRaw);
        }
        return false;
    }

    out->classIndex = classIndex;
    out->code = ecgClassShortName(classIndex);
    out->sourceFile = QFileInfo(path).fileName();

    // The engines get the quantised beat exactly as stored -- no conversion.
    out->modelInput.reserve(values.size());
    for (const double value : values)
    {
        out->modelInput.append(static_cast<qint16>(value));
    }

    // The streaming view plots real amplitudes, so reverse the quantisation
    // here. This is the only place the display morphology is derived, so it is
    // the only place the reverse conversion is needed.
    QVector<double> dequantized;
    dequantized.reserve(values.size());
    for (const double value : values)
    {
        dequantized.append(value / static_cast<double>(BeatPreprocessor::kScale));
    }

    out->displayWave = prepareDisplayWave(classIndex, dequantized, &out->sourceStop, &out->displayRIndex);
    return !out->displayWave.isEmpty();
}

FixedBeat FixedBeatLibrary::makeBeatFromQ88(const int classIndex,
                                           const QVector<qint16> &samples)
{
    FixedBeat out;
    if (samples.size() != kModelInputSamples) return out;

    out.classIndex = classIndex;
    out.code = ecgClassShortName(classIndex);
    out.sourceFile = QStringLiteral("serial");
    out.modelInput = samples;

    QVector<double> dequantized;
    dequantized.reserve(samples.size());
    for (const qint16 raw : samples)
    {
        dequantized.append(static_cast<double>(raw) / static_cast<double>(BeatPreprocessor::kScale));
    }

    out.displayWave = prepareDisplayWave(classIndex, dequantized, &out.sourceStop, &out.displayRIndex);
    return out;
}

int FixedBeatLibrary::lastSignalIndex(const QVector<double> &row)
{
    double maxAbs = 0.0;
    for (const double value : row)
    {
        maxAbs = std::max(maxAbs, std::abs(value));
    }
    const double tolerance = std::max(1.0e-8, maxAbs * 1.0e-7);
    for (int i = row.size() - 1; i >= 0; --i)
    {
        if (std::abs(row[i]) > tolerance)
        {
            return i;
        }
    }
    return row.size() - 1;
}

int FixedBeatLibrary::findFollowingQrs(const QVector<double> &row)
{
    if (row.size() < 43)
    {
        return -1;
    }

    const auto minMax = std::minmax_element(row.begin(), row.end());
    const double span = *minMax.second - *minMax.first;
    if (span < 1.0e-8)
    {
        return -1;
    }
    const double threshold = *minMax.first + 0.62 * span;

    for (int i = 40; i + 1 < row.size(); ++i)
    {
        if (row[i] >= threshold && row[i] > row[i - 1] && row[i] >= row[i + 1])
        {
            return i;
        }
    }
    return -1;
}

QVector<double> FixedBeatLibrary::prepareDisplayWave(const int classIndex,
                                                     const QVector<double> &row,
                                                     int *sourceStop,
                                                     int *displayRIndex)
{
    const int nextR = findFollowingQrs(row);
    int stop = 0;
    double baseline = 0.0;

    if (nextR >= 0)
    {
        stop = std::max(20, nextR - kQrsGuardSamples);
        const int quietLength = std::min(16, std::max(6, stop / 4));
        const int quietStart = std::max(8, stop - quietLength);
        baseline = medianOf(row.mid(quietStart, stop - quietStart));
    }
    else
    {
        const int last = lastSignalIndex(row);
        stop = std::min(static_cast<int>(row.size()), std::max(20, last + 1));
        if (row.size() - stop >= 6)
        {
            baseline = medianOf(row.mid(stop));
        }
        else
        {
            const int quietLength = std::min(16, std::max(6, stop / 4));
            baseline = medianOf(row.mid(std::max(0, stop - quietLength), quietLength));
        }
    }

    QVector<double> out;
    out.reserve(stop);
    for (int i = 0; i < stop; ++i)
    {
        out.append(row[i] - baseline);
    }

    const int qrsWindow = std::min(35, static_cast<int>(out.size()));
    double qrsAmplitude = 0.0;
    int rIndex = 0;
    for (int i = 0; i < qrsWindow; ++i)
    {
        const double amplitude = std::abs(out[i]);
        if (amplitude > qrsAmplitude)
        {
            qrsAmplitude = amplitude;
            rIndex = i;
        }
    }
    if (!std::isfinite(qrsAmplitude) || qrsAmplitude < 1.0e-6)
    {
        qrsAmplitude = 1.0;
    }

    const double scale = kTargetQrs[classIndex] / qrsAmplitude;
    for (double &value : out)
    {
        value *= scale;
    }

    const int edge = std::min(kEdgeTaperSamples, std::max(0, static_cast<int>(out.size()) - 2));
    if (edge > 1)
    {
        constexpr double kPi = 3.14159265358979323846;
        for (int i = 0; i < edge; ++i)
        {
            const double fade = 0.5 + 0.5 * std::cos(kPi * static_cast<double>(i) / static_cast<double>(edge - 1));
            out[out.size() - edge + i] *= fade;
        }
    }
    if (!out.isEmpty())
    {
        out.last() = 0.0;
    }

    if (sourceStop != nullptr)
    {
        *sourceStop = stop;
    }
    if (displayRIndex != nullptr)
    {
        *displayRIndex = rIndex;
    }
    return out;
}
