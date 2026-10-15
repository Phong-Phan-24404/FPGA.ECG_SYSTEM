#pragma once

#include <QVector>
#include <QtGlobal>

// The dataset beats now arrive already quantised to Q8.8 -- see
// kv260_bringup/quantize. Nothing inside app3 quantises any more, so every
// engine starts from exactly the bits the RTL will see, and the fixed-point
// format is defined in exactly one place.
//
// What remains here is the reverse direction: turning Q8.8 back into real
// units for the engines and displays that work in float.
namespace BeatPreprocessor
{
constexpr int kModelInputSamples = 187;

// Q8.8: 8 fractional bits, so 1.0 is stored as 256.
constexpr int kFractionBits = 8;
constexpr float kScale = 256.0f;

// The MIT-BIH amplitudes are normalised to [0, 1], which in Q8.8 is [0, 256].
constexpr int kMinRaw = 0;
constexpr int kMaxRaw = 256;

bool validateQ88Beat187(const QVector<qint16> &beat);

// The reverse of quantisation: Q8.8 -> float, back in the original [0, 1] units.
float toFloat(qint16 raw);
QVector<float> toFloat(const QVector<qint16> &beat);
}
