#pragma once

#include <QString>
#include <QVector>
#include <QtGlobal>

struct FixedBeat
{
    int classIndex = 0;
    QString code;
    QString sourceFile;
    // The 187-point dataset sample, already quantised to Q8.8 in the data file.
    // It is handed to every engine unchanged, so no engine quantises.
    QVector<qint16> modelInput;
    // Display-only morphology, in the original [0, 1] units. Built by reversing
    // the quantisation, because the streaming view plots real amplitudes.
    QVector<double> displayWave;
    int displayRIndex = 0;
    int sourceStop = 0;
};

class FixedBeatLibrary
{
public:
    static constexpr int kClassCount = 5;
    static constexpr int kModelInputSamples = 187;

    bool load(const QString &dataDirectory, QString *errorMessage = nullptr);

    // Dung mot FixedBeat tu khung Q8.8 nhan duoc luc chay (tu ESP32), dung
    // cung phep cat va cung cach tim dinh R nhu khi nap tu tep. Nho vay nhip
    // hien thi tu nguon ngoai giong het nhip nap tu data/, va data/ that su
    // chi con la ban du phong.
    static FixedBeat makeBeatFromQ88(int classIndex, const QVector<qint16> &samples);
    bool isLoaded() const;
    const FixedBeat &beat(int classIndex) const;
    int maxDisplayTemplateLength() const;
    QString summary() const;

private:
    bool loadOne(int classIndex, const QString &path, FixedBeat *out, QString *errorMessage);
    static int findFollowingQrs(const QVector<double> &row);
    static int lastSignalIndex(const QVector<double> &row);
    static QVector<double> prepareDisplayWave(int classIndex,
                                              const QVector<double> &row,
                                              int *sourceStop,
                                              int *displayRIndex);

    QVector<FixedBeat> beats_;
    bool loaded_ = false;
    int maxDisplayTemplateLength_ = 0;
};
