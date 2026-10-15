#include "display_processor.h"

#include <array>

DisplayProcessor::DisplayProcessor()
{
    reset();
}

void DisplayProcessor::reset()
{
    for (SosState &state : state_)
    {
        state = {};
    }
}

QVector<double> DisplayProcessor::process(const QVector<double> &input)
{
    // 2nd-order Butterworth band-pass, 0.05-40 Hz at 125 Hz, represented as
    // two SOS sections. This path is display-only and never feeds the CNN.
    static constexpr std::array<std::array<double, 6>, 2> sos = {{
        {{0.43384588, 0.86769176, 0.43384588, 1.0, 0.51860058, 0.21987305}},
        {{1.0, -2.0, 1.0, 1.0, -1.99644570, 0.99645201}}
    }};

    QVector<double> output;
    output.reserve(input.size());

    for (const double inputValue : input)
    {
        double x = inputValue;
        for (int section = 0; section < 2; ++section)
        {
            const auto &c = sos[section];
            const double y = c[0] * x + state_[section].z1;
            state_[section].z1 = c[1] * x - c[4] * y + state_[section].z2;
            state_[section].z2 = c[2] * x - c[5] * y;
            x = y;
        }
        output.append(x);
    }
    return output;
}
