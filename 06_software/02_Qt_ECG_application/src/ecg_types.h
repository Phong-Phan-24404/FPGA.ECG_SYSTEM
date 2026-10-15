#pragma once

#include <QString>
#include <QVector>

struct BeatEvent
{
    qint64 rSample = 0;
    int classIndex = 0;
};

struct SignalBlock
{
    QVector<double> raw;
    QVector<BeatEvent> events;
};

struct AiBeatResult
{
    bool valid = false;
    int beatIndex = 0;
    int classIndex = -1;
    QString label;
    QString displayLabel;
    QString runtime;
    double timeSeconds = 0.0;
    float confidence = 0.0f;
    QVector<float> probabilities;
};

// One classifier result plus the actual monitor signal captured around it.
// For abnormal events, the controller fills a three-beat context made from:
//   previous beat -> reported/problem beat -> following beat.
// The signal is captured from SignalBuffer after noise/baseline/filtering, so
// doctor review shows the waveform that actually appeared on the monitor rather
// than a clean class template.
struct HistoryRecord
{
    AiBeatResult result;

    QVector<double> rawSignal;
    QVector<double> processedSignal;

    int previousRIndex = -1;
    int problemRIndex = -1;
    int nextRIndex = -1;

    int previousClassIndex = -1;
    int problemClassIndex = -1;
    int nextClassIndex = -1;

    bool contextReady = false;
    bool reviewed = false;
};

inline QString ecgClassShortName(const int index)
{
    static const QVector<QString> labels = {"N", "S", "V", "F", "Q"};
    return index >= 0 && index < labels.size() ? labels[index] : "?";
}

inline QString ecgClassLongName(const int index)
{
    static const QVector<QString> labels = {
        "Normal / non-ectopic",
        "Supraventricular ectopic",
        "Ventricular ectopic",
        "Fusion",
        "Unknown / unclassifiable"};
    return index >= 0 && index < labels.size() ? labels[index] : "Unknown";
}
