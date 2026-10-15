#pragma once

#include "ecg_types.h"

#include <QString>
#include <QVector>
#include <QtGlobal>

#include <memory>

enum class ClassifierBackend
{
    Rtl = 0,
    Cpu = 1,
    Dpu = 2
};

class IHeartbeatClassifier
{
public:
    virtual ~IHeartbeatClassifier() = default;
    virtual bool load(const QString &modelPath, QString *message = nullptr) = 0;
    virtual bool isLoaded() const = 0;
    virtual QString runtimeName() const = 0;
    virtual QString statusText() const = 0;
    // The beat arrives already quantised to Q8.8; engines that need real
    // units reverse it themselves via BeatPreprocessor::toFloat.
    virtual AiBeatResult classify187(const QVector<qint16> &beatQ88) = 0;
};

QString classifierBackendName(ClassifierBackend backend);
bool classifierBackendCompiled(ClassifierBackend backend);
ClassifierBackend defaultHeartbeatClassifierBackend();
std::shared_ptr<IHeartbeatClassifier> createHeartbeatClassifier(ClassifierBackend backend);
std::shared_ptr<IHeartbeatClassifier> createDefaultHeartbeatClassifier();
