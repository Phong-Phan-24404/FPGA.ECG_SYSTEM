#pragma once

#include <QVector>

class DisplayProcessor
{
public:
    DisplayProcessor();
    void reset();
    QVector<double> process(const QVector<double> &input);

private:
    struct SosState
    {
        double z1 = 0.0;
        double z2 = 0.0;
    };
    SosState state_[2];
};
