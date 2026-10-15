#include "demo_controller.h"
#include "display_processor.h"
#include "fixed_beat_library.h"
#include "rhythm_emulator.h"
#include "ai/heartbeat_classifier.h"

#include <QApplication>
#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QDebug>
#include <QStringList>
#include <QTimer>

#include <cmath>
#include <cstring>
#include <iostream>

namespace
{
QString resolveDataDirectory()
{
    const QString envPath = qEnvironmentVariable("ECG_DATA_DIR").trimmed();
    if (!envPath.isEmpty() && QDir(envPath).exists()) return QDir(envPath).absolutePath();
    const QString appDir = QCoreApplication::applicationDirPath();
    const QStringList candidates = {
        appDir + "/data",
        appDir + "/../data",
        QDir::currentPath() + "/data",
        QDir::currentPath() + "/../data"};
    for (const QString &candidate : candidates)
    {
        if (QFileInfo::exists(candidate + "/sampleN.txt")) return QDir(candidate).absolutePath();
    }
    return QDir(candidates.first()).absolutePath();
}

int runSelfTest()
{
    FixedBeatLibrary library;
    QString error;
    if (!library.load(resolveDataDirectory(), &error))
    {
        std::cerr << "[FAIL] " << error.toStdString() << '\n';
        return 1;
    }

    for (int classIndex = 0; classIndex < FixedBeatLibrary::kClassCount; ++classIndex)
    {
        const FixedBeat &beat = library.beat(classIndex);
        if (beat.modelInput.size() != FixedBeatLibrary::kModelInputSamples || beat.displayWave.isEmpty())
        {
            std::cerr << "[FAIL] invalid beat " << classIndex << '\n';
            return 1;
        }
        std::cout << "[PASS] sample " << beat.code.toStdString()
                  << ": 187 model points, " << beat.displayWave.size() << " display points\n";
    }

    // Honour --backend / ECG_BACKEND. This used to be hardwired to Cpu, which
    // meant --self-test reported PASS for every backend -- including ones not
    // compiled into this build -- while only ever exercising the CPU path. The
    // RTL and DPU backends are the ones with runtime dependencies (the PL
    // overlay, pl_dmabuf, /dev/mem, the Vitis AI runtime), so they are exactly
    // the ones a self-test needs to cover.
    const ClassifierBackend backend = defaultHeartbeatClassifierBackend();
    auto classifier = createHeartbeatClassifier(backend);
    if (!classifier)
    {
        // createHeartbeatClassifier returns null for a backend this build does
        // not contain; dereferencing it below would be a segfault.
        std::cerr << "[FAIL] backend " << classifierBackendName(backend).toStdString()
                  << " is not compiled into this build\n";
        return 1;
    }

    QString classifierMessage;
    const QString modelPath = QCoreApplication::applicationDirPath() + "/models/ecg_1dcnn_2d_dpu.xmodel";
    if (!classifier->load(modelPath, &classifierMessage))
    {
        std::cerr << "[FAIL] classifier (" << classifierBackendName(backend).toStdString()
                  << "): " << classifierMessage.toStdString() << '\n';
        return 1;
    }
    std::cout << "[INFO] backend " << classifierBackendName(backend).toStdString()
              << " active, runtime: " << classifier->runtimeName().toStdString() << '\n';
    for (int classIndex = 0; classIndex < FixedBeatLibrary::kClassCount; ++classIndex)
    {
        const AiBeatResult result = classifier->classify187(library.beat(classIndex).modelInput);
        if (!result.valid || result.classIndex < 0 || result.classIndex >= FixedBeatLibrary::kClassCount ||
            !std::isfinite(result.confidence) || result.confidence <= 0.0f)
        {
            std::cerr << "[FAIL] classifier returned no valid result for sample "
                      << classIndex << '\n';
            return 1;
        }
        std::cout << "[PASS] classifier " << ecgClassShortName(classIndex).toStdString()
                  << " -> " << result.label.toStdString() << " ("
                  << result.confidence << ")\n";
    }

    for (int mode = 0; mode < FixedBeatLibrary::kClassCount; ++mode)
    {
        RhythmEmulator emulator(&library);
        emulator.setMode(mode);
        DisplayProcessor processor;
        int events = 0;
        for (int tick = 0; tick < 375; ++tick) // 15 seconds at 40 ms/tick
        {
            const SignalBlock block = emulator.nextSamples(5);
            const QVector<double> filtered = processor.process(block.raw);
            events += block.events.size();
            if (block.raw.size() != 5 || filtered.size() != 5)
            {
                std::cerr << "[FAIL] block size mismatch in mode " << mode << '\n';
                return 1;
            }
            for (const double value : filtered)
            {
                if (!std::isfinite(value))
                {
                    std::cerr << "[FAIL] non-finite signal in mode " << mode << '\n';
                    return 1;
                }
            }
        }
        if (events < 5)
        {
            std::cerr << "[FAIL] too few scheduled beats in mode " << mode << '\n';
            return 1;
        }
        std::cout << "[PASS] rhythm " << ecgClassShortName(mode).toStdString()
                  << ": " << events << " beat events in 15 s\n";
    }

    std::cout << "SELF-TEST PASS\n";
    return 0;
}
}

int main(int argc, char *argv[])
{
    bool selfTest = false;
    bool guiSmokeTest = false;
    bool backendSwitchTest = false;
    QString requestedBackend;
    for (int i = 1; i < argc; ++i)
    {
        if (std::strcmp(argv[i], "--self-test") == 0) selfTest = true;
        if (std::strcmp(argv[i], "--gui-smoke-test") == 0) guiSmokeTest = true;
        if (std::strcmp(argv[i], "--backend-switch-test") == 0) backendSwitchTest = true;
        if (std::strcmp(argv[i], "--backend") == 0 && i + 1 < argc)
        {
            requestedBackend = QString::fromLocal8Bit(argv[++i]).trimmed().toLower();
        }
    }

    if (!requestedBackend.isEmpty())
    {
        if (requestedBackend != "rtl" && requestedBackend != "cpu" && requestedBackend != "dpu")
        {
            std::cerr << "[FAIL] --backend must be rtl, cpu, or dpu\n";
            return 2;
        }
        qputenv("ECG_BACKEND", requestedBackend.toLocal8Bit());
    }

    if (selfTest)
    {
        QCoreApplication app(argc, argv);
        QCoreApplication::setApplicationName("ECG AI Monitor Self-Test");
        return runSelfTest();
    }

    QApplication app(argc, argv);
    QApplication::setApplicationName("Realtime ECG AI Monitor");
    QApplication::setOrganizationName("ECG Demo");

    qInfo().noquote() << "[STARTUP] Qt platform:" << QGuiApplication::platformName();
    qInfo().noquote() << "[STARTUP] DISPLAY:" << qEnvironmentVariable("DISPLAY");
    qInfo().noquote() << "[STARTUP] XDG_RUNTIME_DIR:" << qEnvironmentVariable("XDG_RUNTIME_DIR");
    qInfo().noquote() << "[STARTUP] Constructing DemoController...";

    DemoController controller;
    qInfo().noquote() << "[STARTUP] DemoController constructed.";
    controller.show();
    qInfo().noquote() << "[STARTUP] Main window shown.";


    if (backendSwitchTest)
    {
        // Exercise the production switch path: invokeMethod reaches the same
        // private slot that DemoWindow::backendChanged is connected to, so this
        // tests DemoController::setBackend -> activateBackend exactly as a
        // click would. The markers let a shell script sample the process table
        // at the right moments and confirm no CPU worker survives into RTL.
        QTimer::singleShot(1000, &controller, [&controller] {
            qInfo().noquote() << "[SWITCHTEST] selecting CPU";
            QMetaObject::invokeMethod(&controller, "setBackend", Qt::DirectConnection,
                                      Q_ARG(int, static_cast<int>(ClassifierBackend::Cpu)));
            qInfo().noquote() << "[SWITCHTEST] CPU selected";
        });
        QTimer::singleShot(3000, &controller, [&controller] {
            qInfo().noquote() << "[SWITCHTEST] selecting RTL";
            QMetaObject::invokeMethod(&controller, "setBackend", Qt::DirectConnection,
                                      Q_ARG(int, static_cast<int>(ClassifierBackend::Rtl)));
            qInfo().noquote() << "[SWITCHTEST] RTL selected";
        });
        QTimer::singleShot(6000, &app, &QCoreApplication::quit);
    }
    else if (guiSmokeTest)
    {
        qInfo().noquote() << "[STARTUP] GUI smoke test: exiting after 1500 ms.";
        QTimer::singleShot(1500, &app, &QCoreApplication::quit);
    }

    return app.exec();
}
