#include "ai/heartbeat_classifier.h"

#include "ai/beat_preprocessor.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QRegularExpression>
#include <QStringList>
#include <QTextStream>
#include <QtGlobal>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <vector>

#ifdef Q_OS_LINUX
#include <cerrno>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#endif

#ifdef ECG_ENABLE_VITIS_AI
#include <vart/runner_ext.hpp>
#include <xir/attrs/attrs.hpp>
#include <xir/graph/graph.hpp>
#include <xir/subgraph.hpp>
#include <xir/tensor/tensor.hpp>
#endif

namespace
{
AiBeatResult makeResultFromProbabilities(const QVector<float> &probabilities)
{
    AiBeatResult result;
    if (probabilities.size() != 5)
    {
        return result;
    }
    const auto maxIt = std::max_element(probabilities.begin(), probabilities.end());
    const int classIndex = static_cast<int>(std::distance(probabilities.begin(), maxIt));
    result.valid = true;
    result.classIndex = classIndex;
    result.label = ecgClassShortName(classIndex);
    result.displayLabel = QString("%1 (%2)").arg(ecgClassLongName(classIndex), result.label);
    result.confidence = *maxIt;
    result.probabilities = probabilities;
    return result;
}

QVector<float> softmax(const QVector<float> &values)
{
    QVector<float> probabilities(values.size(), 0.0f);
    if (values.isEmpty())
    {
        return probabilities;
    }
    const float maxValue = *std::max_element(values.begin(), values.end());
    double sum = 0.0;
    for (int i = 0; i < values.size(); ++i)
    {
        probabilities[i] = std::exp(values[i] - maxValue);
        sum += probabilities[i];
    }
    if (sum <= 0.0)
    {
        return {};
    }
    for (float &value : probabilities)
    {
        value = static_cast<float>(static_cast<double>(value) / sum);
    }
    return probabilities;
}

// The FP32 CNN, served by a long-lived python3 worker over pipes.
//
// This is the same network the PL runs, in float, so RTL and CPU finally
// compare like for like: same architecture, same weights, different arithmetic
// (Q8.8 fixed point against FP32). The previous CPU backend was a
// nearest-prototype matcher that loaded no CNN weights at all and so could not
// be compared against the accelerator on equal terms; it is kept below as
// PrototypeMatchClassifier.
//
// The worker is started once and kept alive. Spawning python3 per beat would
// cost far more in interpreter start-up, NumPy import and weight loading than
// the inference itself.
class CnnPythonClassifier final : public IHeartbeatClassifier
{
public:
    ~CnnPythonClassifier() override { stopWorker(); }

    // Ask politely, then insist. Closing stdin alone would suffice -- the
    // worker's read loop ends at EOF -- but an explicit QUIT lets it exit
    // cleanly, and the kill guarantees no worker outlives this backend even if
    // the interpreter is wedged. waitForFinished after kill reaps the child so
    // it cannot linger as a zombie.
    void stopWorker()
    {
        if (!process_) return;
        if (process_->state() != QProcess::NotRunning)
        {
            process_->write("QUIT\n");
            process_->closeWriteChannel();
            if (!process_->waitForFinished(1000))
            {
                process_->kill();
                process_->waitForFinished(1000);
            }
        }
        process_.reset();
        loaded_ = false;
    }

    bool load(const QString &, QString *message) override
    {
        const QString script = resolveWorkerScript();
        if (script.isEmpty())
        {
            if (message) *message = "CPU CNN: ecg_cpu_worker.py not found beside the executable.";
            return false;
        }

        process_.reset(new QProcess);
        process_->setProcessChannelMode(QProcess::SeparateChannels);
        process_->start("python3", QStringList{script});
        if (!process_->waitForStarted(5000))
        {
            if (message) *message = "CPU CNN: could not start python3.";
            process_.reset();
            return false;
        }

        // READY is printed only after NumPy is imported and the weights are
        // loaded, so a missing handshake means a real failure, not slowness.
        if (!process_->waitForReadyRead(20000))
        {
            if (message)
            {
                *message = QString("CPU CNN: worker did not report READY. %1")
                               .arg(QString::fromLocal8Bit(process_->readAllStandardError()).trimmed());
            }
            process_.reset();
            return false;
        }
        const QString handshake = QString::fromLocal8Bit(process_->readLine()).trimmed();
        if (!handshake.startsWith("READY"))
        {
            if (message)
            {
                *message = QString("CPU CNN: unexpected handshake '%1'. %2")
                               .arg(handshake,
                                    QString::fromLocal8Bit(process_->readAllStandardError()).trimmed());
            }
            process_.reset();
            return false;
        }

        loaded_ = true;
        if (message) *message = "CPU CNN (Python/NumPy FP32) ready";
        return true;
    }

    bool isLoaded() const override { return loaded_; }
    QString runtimeName() const override { return "CPU FP32 CNN (Python/NumPy)"; }
    QString statusText() const override { return loaded_ ? "Ready" : "Not loaded"; }

    AiBeatResult classify187(const QVector<qint16> &beatQ88) override
    {
        if (!loaded_ || !process_ || process_->state() != QProcess::Running) return {};
        if (!BeatPreprocessor::validateQ88Beat187(beatQ88)) return {};

        // This engine is FP32, so the quantised beat is reversed back to real
        // units here. The worker then sees exactly what the float reference
        // model was validated against.
        const QVector<float> input = BeatPreprocessor::toFloat(beatQ88);

        QByteArray request;
        request.reserve(input.size() * 12);
        for (int i = 0; i < input.size(); ++i)
        {
            if (i) request += ' ';
            request += QByteArray::number(input[i], 'g', 9);
        }
        request += '\n';

        if (process_->write(request) != request.size()) return {};
        if (!process_->waitForBytesWritten(2000)) return {};

        // One request, one reply. readLine can return a partial line before the
        // worker flushes, so keep reading until a whole line has arrived.
        QByteArray reply;
        while (!reply.endsWith('\n'))
        {
            if (!process_->waitForReadyRead(5000)) return {};
            reply += process_->readLine();
        }

        const QString line = QString::fromLocal8Bit(reply).trimmed();
        if (!line.startsWith("OK ")) return {};   // ERR, or anything unexpected

        const QStringList parts = line.mid(3).split(QRegularExpression("\\s+"),
                                                    Qt::SkipEmptyParts);
        if (parts.size() != 5) return {};

        QVector<float> logits;
        logits.reserve(5);
        for (const QString &part : parts)
        {
            bool ok = false;
            const float value = part.toFloat(&ok);
            if (!ok || !std::isfinite(value)) return {};
            logits.append(value);
        }

        AiBeatResult result = makeResultFromProbabilities(softmax(logits));
        result.runtime = runtimeName();
        return result;
    }

private:
    static QString resolveWorkerScript()
    {
        const QString appDir = QCoreApplication::applicationDirPath();
        const QStringList candidates = {
            appDir + "/python/ecg_cpu_worker.py",
            appDir + "/../python/ecg_cpu_worker.py",
            QDir::currentPath() + "/python/ecg_cpu_worker.py"};
        for (const QString &candidate : candidates)
        {
            if (QFileInfo::exists(candidate)) return QFileInfo(candidate).absoluteFilePath();
        }
        return {};
    }

    bool loaded_ = false;
    std::unique_ptr<QProcess> process_;
};

// Retained for reference and as a dependency-free fallback: nearest-prototype
// matching against the five fixed beats in data/. It loads no CNN weights, so
// it cannot be compared against the PL accelerator on equal terms.
class PrototypeMatchClassifier final : public IHeartbeatClassifier
{
public:
    bool load(const QString &, QString *message) override
    {
        const QString appDir = QCoreApplication::applicationDirPath();
        const QStringList candidates = {
            appDir + "/data",
            appDir + "/../data",
            QDir::currentPath() + "/data",
            QDir::currentPath() + "/../data"};
        const QStringList files = {"sampleN.txt", "sampleS.txt", "sampleV.txt", "sampleF.txt", "sampleQ.txt"};
        for (const QString &directory : candidates)
        {
            QVector<QVector<float>> prototypes;
            bool validDirectory = true;
            for (const QString &fileName : files)
            {
                QFile file(directory + "/" + fileName);
                if (!file.open(QIODevice::ReadOnly | QIODevice::Text))
                {
                    validDirectory = false;
                    break;
                }
                QVector<float> sample;
                QTextStream stream(&file);
                while (!stream.atEnd())
                {
                    const QStringList tokens = stream.readLine().trimmed().split(
                        QRegularExpression("[,;\\s]+"), Qt::SkipEmptyParts);
                    for (const QString &token : tokens)
                    {
                        bool ok = false;
                        const float value = token.toFloat(&ok);
                        if (!ok || !std::isfinite(value))
                        {
                            validDirectory = false;
                            break;
                        }
                        // The data files hold Q8.8 now, so the prototypes are
                        // reversed to real units on load. Both sides of the
                        // distance then live in the same units as before.
                        sample.append(value / BeatPreprocessor::kScale);
                    }
                    if (!validDirectory) break;
                }
                if (sample.size() != BeatPreprocessor::kModelInputSamples)
                {
                    validDirectory = false;
                    break;
                }
                prototypes.append(sample);
            }
            if (validDirectory && prototypes.size() == 5)
            {
                prototypes_ = prototypes;
                loaded_ = true;
                if (message != nullptr) *message = "CPU classifier ready";
                return true;
            }
        }
        if (message != nullptr)
        {
            *message = "CPU classifier could not load the five reference samples.";
        }
        return false;
    }

    bool isLoaded() const override { return loaded_; }
    QString runtimeName() const override { return "CPU Prototype Match (no CNN)"; }
    QString statusText() const override { return loaded_ ? "Ready" : "Not loaded"; }

    AiBeatResult classify187(const QVector<qint16> &beatQ88) override
    {
        if (!loaded_ || !BeatPreprocessor::validateQ88Beat187(beatQ88)) return {};

        // Distances are computed in real units, so the fixed -1000x softmax
        // scaling below keeps the meaning it had before the data was quantised.
        const QVector<float> input = BeatPreprocessor::toFloat(beatQ88);

        QVector<float> distances;
        distances.reserve(prototypes_.size());
        for (const QVector<float> &prototype : prototypes_)
        {
            double sum = 0.0;
            for (int i = 0; i < input.size(); ++i)
            {
                const double delta = static_cast<double>(input[i]) - prototype[i];
                sum += delta * delta;
            }
            distances.append(static_cast<float>(sum / input.size()));
        }

        QVector<float> scores;
        scores.reserve(distances.size());
        for (const float distance : distances) scores.append(-distance * 1000.0f);
        AiBeatResult result = makeResultFromProbabilities(softmax(scores));
        result.runtime = runtimeName();
        return result;
    }

private:
    bool loaded_ = false;
    QVector<QVector<float>> prototypes_;
};

#ifdef Q_OS_LINUX
class RtlPlHeartbeatClassifier final : public IHeartbeatClassifier
{
public:
    ~RtlPlHeartbeatClassifier() override { release(); }

    bool load(const QString &, QString *message) override
    {
        release();

#if !defined(__aarch64__) && !defined(__arm__)
        if (message != nullptr)
        {
            *message = "RTL PL backend is intended for the AArch64 Kria KV260 runtime.";
        }
        return false;
#else
        QFile physFile(QString::fromLatin1(kPhysAttr));
        if (!physFile.open(QIODevice::ReadOnly | QIODevice::Text))
        {
            if (message != nullptr)
            {
                *message = "RTL backend: pl_dmabuf is not loaded. Run scripts/prepare_rtl_kv260.sh first.";
            }
            return false;
        }
        bool physOk = false;
        const QByteArray physText = physFile.readAll().trimmed();
        phys_ = QString::fromLatin1(physText).toULongLong(&physOk, 0);
        if (!physOk || phys_ == 0 || phys_ + kBufferMapSize > 0x100000000ULL)
        {
            if (message != nullptr) *message = "RTL backend: invalid 32-bit DMA buffer address.";
            release();
            return false;
        }

        bufferFd_ = ::open(kBufferDevice, O_RDWR);
        if (bufferFd_ < 0)
        {
            if (message != nullptr)
            {
                *message = QString("RTL backend: cannot open %1: %2")
                               .arg(QString::fromLatin1(kBufferDevice), QString::fromLocal8Bit(std::strerror(errno)));
            }
            release();
            return false;
        }

        void *bufferMap = ::mmap(nullptr, kBufferMapSize, PROT_READ | PROT_WRITE,
                                 MAP_SHARED, bufferFd_, 0);
        if (bufferMap == MAP_FAILED)
        {
            if (message != nullptr)
            {
                *message = QString("RTL backend: mmap %1 failed: %2")
                               .arg(QString::fromLatin1(kBufferDevice), QString::fromLocal8Bit(std::strerror(errno)));
            }
            release();
            return false;
        }
        buffer_ = static_cast<std::uint8_t *>(bufferMap);

        memFd_ = ::open("/dev/mem", O_RDWR | O_SYNC);
        if (memFd_ < 0)
        {
            if (message != nullptr)
            {
                *message = QString("RTL backend: cannot open /dev/mem: %1. Run the app with root/CAP_SYS_RAWIO for RTL mode.")
                               .arg(QString::fromLocal8Bit(std::strerror(errno)));
            }
            release();
            return false;
        }

        void *dmaMap = ::mmap(nullptr, kRegisterMapSize, PROT_READ | PROT_WRITE,
                              MAP_SHARED, memFd_, kDmaBase);
        void *cnnMap = ::mmap(nullptr, kRegisterMapSize, PROT_READ | PROT_WRITE,
                              MAP_SHARED, memFd_, kCnnBase);
        if (dmaMap == MAP_FAILED || cnnMap == MAP_FAILED)
        {
            if (dmaMap != MAP_FAILED) ::munmap(dmaMap, kRegisterMapSize);
            if (cnnMap != MAP_FAILED) ::munmap(cnnMap, kRegisterMapSize);
            if (message != nullptr)
            {
                *message = QString("RTL backend: AXI register mmap failed: %1")
                               .arg(QString::fromLocal8Bit(std::strerror(errno)));
            }
            release(false);
            return false;
        }
        dmaRegs_ = static_cast<volatile std::uint8_t *>(dmaMap);
        cnnRegs_ = static_cast<volatile std::uint8_t *>(cnnMap);

        // Verify that the expected CNN AXI-Lite register bank is present before
        // the GUI reports RTL as available.
        write32(cnnRegs_, kCnnGie, 1u);
        if (read32(cnnRegs_, kCnnGie) != 1u)
        {
            write32(cnnRegs_, kCnnGie, 0u);
            if (message != nullptr)
            {
                *message = "RTL backend: CNN AXI-Lite readback failed. Verify that the custom PL bitstream is loaded.";
            }
            release();
            return false;
        }
        write32(cnnRegs_, kCnnGie, 0u);

        loaded_ = true;
        if (message != nullptr)
        {
            *message = QString("RTL accelerator ready · DMA buffer 0x%1")
                           .arg(static_cast<qulonglong>(phys_), 8, 16, QLatin1Char('0'));
        }
        return true;
#endif
    }

    bool isLoaded() const override { return loaded_; }
    QString runtimeName() const override { return "RTL PL Accelerator"; }
    QString statusText() const override { return loaded_ ? "Ready" : "Not loaded"; }

    AiBeatResult classify187(const QVector<qint16> &beatQ88) override
    {
#if !defined(__aarch64__) && !defined(__arm__)
        Q_UNUSED(beatQ88);
        return {};
#else
        if (!loaded_ || buffer_ == nullptr) return {};
        if (!BeatPreprocessor::validateQ88Beat187(beatQ88)) return {};

        auto *inputWords = reinterpret_cast<std::uint32_t *>(buffer_ + kInputOffset);
        auto *outputWords = reinterpret_cast<std::uint16_t *>(buffer_ + kOutputOffset);
        std::memset(buffer_, 0, kBufferMapSize);

        // No conversion: the beat is already the signed Q8.8 the PL expects, and
        // the MM2S datapath takes it in the low 16 bits of each 32-bit word.
        // Rounding once, offline, is what keeps this engine bit-identical to the
        // golden vectors the RTL was verified against.
        for (int i = 0; i < BeatPreprocessor::kModelInputSamples; ++i)
        {
            const auto q = static_cast<std::uint16_t>(beatQ88[i]);
            inputWords[i] = static_cast<std::uint32_t>(q);
        }
        systemBarrier();

        if (!runOnce()) return {};
        systemBarrier();

        // The logits come back in the same Q8.8 the input used, so the same
        // reverse conversion applies -- and the format stays defined in one place.
        QVector<float> logits;
        logits.reserve(kOutputSamples);
        for (int i = 0; i < kOutputSamples; ++i)
        {
            const auto raw = static_cast<std::int16_t>(outputWords[i]);
            logits.append(BeatPreprocessor::toFloat(static_cast<qint16>(raw)));
        }

        AiBeatResult result = makeResultFromProbabilities(softmax(logits));
        result.runtime = runtimeName();
        return result;
#endif
    }

private:
    static constexpr std::uintptr_t kDmaBase = 0x80010000UL;
    static constexpr std::uintptr_t kCnnBase = 0x80020000UL;
    static constexpr std::size_t kRegisterMapSize = 0x10000UL;
    static constexpr std::size_t kBufferMapSize = 0x2000UL;
    static constexpr int kOutputSamples = 5;
    static constexpr std::uint32_t kInputOffset = 0x0000u;
    static constexpr std::uint32_t kOutputOffset = 0x1000u;
    static constexpr std::uint32_t kMm2sBytes = BeatPreprocessor::kModelInputSamples * 4u;
    static constexpr std::uint32_t kS2mmBytes = kOutputSamples * 2u;
    static constexpr const char *kPhysAttr = "/sys/module/pl_dmabuf/parameters/phys_addr";
    static constexpr const char *kBufferDevice = "/dev/pl_dmabuf";

    static constexpr std::uint32_t kMm2sDmacr = 0x00;
    static constexpr std::uint32_t kMm2sDmasr = 0x04;
    static constexpr std::uint32_t kMm2sSa = 0x18;
    static constexpr std::uint32_t kMm2sLength = 0x28;
    static constexpr std::uint32_t kS2mmDmacr = 0x30;
    static constexpr std::uint32_t kS2mmDmasr = 0x34;
    static constexpr std::uint32_t kS2mmDa = 0x48;
    static constexpr std::uint32_t kS2mmLength = 0x58;

    static constexpr std::uint32_t kDmacrRun = 0x00000001u;
    static constexpr std::uint32_t kDmacrReset = 0x00000004u;
    static constexpr std::uint32_t kDmacrIocIrq = 0x00001000u;
    static constexpr std::uint32_t kDmasrIdle = 0x00000002u;
    static constexpr std::uint32_t kDmasrErrorMask = 0x00000070u;

    static constexpr std::uint32_t kCnnCtrl = 0x00;
    static constexpr std::uint32_t kCnnStatus = 0x04;
    static constexpr std::uint32_t kCnnGie = 0x08;
    static constexpr std::uint32_t kCnnIer = 0x0C;
    static constexpr std::uint32_t kCnnIsr = 0x10;

    static void write32(volatile std::uint8_t *base, std::uint32_t offset, std::uint32_t value)
    {
        *reinterpret_cast<volatile std::uint32_t *>(base + offset) = value;
    }

    static std::uint32_t read32(volatile std::uint8_t *base, std::uint32_t offset)
    {
        return *reinterpret_cast<volatile std::uint32_t *>(base + offset);
    }

    static void systemBarrier()
    {
#if defined(__aarch64__) || defined(__arm__)
        __asm__ __volatile__("dsb sy" ::: "memory");
#else
        std::atomic_thread_fence(std::memory_order_seq_cst);
#endif
    }

    bool waitIdle(std::uint32_t statusOffset, QString *error)
    {
        const auto start = std::chrono::steady_clock::now();
        for (;;)
        {
            const std::uint32_t status = read32(dmaRegs_, statusOffset);
            if ((status & kDmasrErrorMask) != 0u)
            {
                if (error != nullptr)
                {
                    *error = QString("DMA error 0x%1").arg(status, 8, 16, QLatin1Char('0'));
                }
                return false;
            }
            if ((status & kDmasrIdle) != 0u) return true;
            const double elapsedMs = std::chrono::duration<double, std::milli>(
                                         std::chrono::steady_clock::now() - start)
                                         .count();
            if (elapsedMs > 1000.0)
            {
                if (error != nullptr)
                {
                    *error = QString("DMA timeout 0x%1").arg(status, 8, 16, QLatin1Char('0'));
                }
                return false;
            }
        }
    }

    bool runOnce()
    {
        write32(dmaRegs_, kMm2sDmacr, kDmacrReset);
        write32(dmaRegs_, kS2mmDmacr, kDmacrReset);
        for (int i = 0; i < 1000; ++i)
        {
            const auto resetBits = read32(dmaRegs_, kMm2sDmacr) | read32(dmaRegs_, kS2mmDmacr);
            if ((resetBits & kDmacrReset) == 0u) break;
        }

        // Match the verified host ordering: receive first, start CNN, launch
        // MM2S by writing LENGTH last.
        write32(dmaRegs_, kS2mmDa, static_cast<std::uint32_t>(phys_ + kOutputOffset));
        write32(dmaRegs_, kS2mmDmacr, kDmacrRun | kDmacrIocIrq);
        write32(dmaRegs_, kS2mmLength, kS2mmBytes);

        write32(cnnRegs_, kCnnGie, 1u);
        write32(cnnRegs_, kCnnIer, 1u);
        write32(cnnRegs_, kCnnIsr, 1u);
        write32(cnnRegs_, kCnnCtrl, 1u);

        write32(dmaRegs_, kMm2sSa, static_cast<std::uint32_t>(phys_ + kInputOffset));
        write32(dmaRegs_, kMm2sDmacr, kDmacrRun | kDmacrIocIrq);
        write32(dmaRegs_, kMm2sLength, kMm2sBytes);

        QString error;
        if (!waitIdle(kMm2sDmasr, &error) || !waitIdle(kS2mmDmasr, &error))
        {
            return false;
        }
        systemBarrier();

        if ((read32(cnnRegs_, kCnnStatus) & 1u) == 0u) return false;
        write32(cnnRegs_, kCnnCtrl, 2u);
        write32(cnnRegs_, kCnnIsr, 1u);
        return true;
    }

    void release(bool unmapRegisters = true)
    {
        loaded_ = false;
        if (unmapRegisters)
        {
            if (dmaRegs_ != nullptr)
            {
                ::munmap(const_cast<std::uint8_t *>(dmaRegs_), kRegisterMapSize);
                dmaRegs_ = nullptr;
            }
            if (cnnRegs_ != nullptr)
            {
                ::munmap(const_cast<std::uint8_t *>(cnnRegs_), kRegisterMapSize);
                cnnRegs_ = nullptr;
            }
        }
        else
        {
            dmaRegs_ = nullptr;
            cnnRegs_ = nullptr;
        }
        if (buffer_ != nullptr)
        {
            ::munmap(buffer_, kBufferMapSize);
            buffer_ = nullptr;
        }
        if (bufferFd_ >= 0)
        {
            ::close(bufferFd_);
            bufferFd_ = -1;
        }
        if (memFd_ >= 0)
        {
            ::close(memFd_);
            memFd_ = -1;
        }
        phys_ = 0;
    }

    bool loaded_ = false;
    int bufferFd_ = -1;
    int memFd_ = -1;
    std::uint64_t phys_ = 0;
    std::uint8_t *buffer_ = nullptr;
    volatile std::uint8_t *dmaRegs_ = nullptr;
    volatile std::uint8_t *cnnRegs_ = nullptr;
};
#endif

#ifdef ECG_ENABLE_VITIS_AI
std::vector<const xir::Subgraph *> collectDpuSubgraphs(const xir::Subgraph *subgraph)
{
    std::vector<const xir::Subgraph *> result;
    if (subgraph == nullptr) return result;
    if (subgraph->has_attr("device") && subgraph->get_attr<std::string>("device") == "DPU")
    {
        result.push_back(subgraph);
        return result;
    }
    for (const auto &child : subgraph->children_topological_sort())
    {
        const auto nested = collectDpuSubgraphs(child);
        result.insert(result.end(), nested.begin(), nested.end());
    }
    return result;
}

int tensorElementCount(const xir::Tensor *tensor)
{
    if (tensor == nullptr) return 0;
    int size = 1;
    for (const int dimension : tensor->get_shape()) size *= std::max(1, dimension);
    return size;
}

int tensorFixPoint(const xir::Tensor *tensor)
{
    return tensor != nullptr && tensor->has_attr("fix_point") ? tensor->get_attr<int>("fix_point") : 0;
}

class DpuXmodelHeartbeatClassifier final : public IHeartbeatClassifier
{
public:
    bool load(const QString &modelPath, QString *message) override
    {
        try
        {
            if (!QFileInfo::exists(modelPath))
            {
                if (message != nullptr) *message = QString("xmodel not found: %1").arg(modelPath);
                return false;
            }
            graph_ = xir::Graph::deserialize(modelPath.toStdString());
            const auto subgraphs = collectDpuSubgraphs(graph_->get_root_subgraph());
            if (subgraphs.empty())
            {
                if (message != nullptr) *message = "The xmodel contains no DPU subgraph.";
                return false;
            }
            auto attrs = xir::Attrs::create();
            runner_ = vart::RunnerExt::create_runner(subgraphs.front(), attrs.get());
            inputBuffers_ = runner_->get_inputs();
            outputBuffers_ = runner_->get_outputs();
            if (inputBuffers_.empty() || outputBuffers_.empty())
            {
                if (message != nullptr) *message = "VART returned no input/output buffers.";
                return false;
            }
            if (tensorElementCount(inputBuffers_[0]->get_tensor()) < BeatPreprocessor::kModelInputSamples)
            {
                if (message != nullptr) *message = "DPU input tensor is smaller than the required 187 samples.";
                return false;
            }
            loaded_ = true;
            if (message != nullptr) *message = "xmodel loaded on DPU";
            return true;
        }
        catch (const std::exception &error)
        {
            if (message != nullptr) *message = QString("Cannot load xmodel: %1").arg(error.what());
            return false;
        }
    }

    bool isLoaded() const override { return loaded_; }
    QString runtimeName() const override { return "Vitis AI DPU"; }
    QString statusText() const override { return loaded_ ? "Ready" : "Not loaded"; }

    AiBeatResult classify187(const QVector<qint16> &beatQ88) override
    {
        if (!loaded_ || !BeatPreprocessor::validateQ88Beat187(beatQ88)) return {};

        // The DPU has its own int8 scale, unrelated to the PL's Q8.8, so the
        // beat is reversed to real units first and then requantised below by
        // the tensor's own fixpoint position.
        const QVector<float> input = BeatPreprocessor::toFloat(beatQ88);

        auto *inputTensor = inputBuffers_[0]->get_tensor();
        auto *outputTensor = outputBuffers_[0]->get_tensor();
        const int inputElements = tensorElementCount(inputTensor);
        const int outputElements = tensorElementCount(outputTensor);
        if (inputElements <= 0 || outputElements < 5) return {};

        const std::vector<int> inputIndex(inputTensor->get_shape().size(), 0);
        const std::vector<int> outputIndex(outputTensor->get_shape().size(), 0);
        auto inputData = inputBuffers_[0]->data(inputIndex);
        auto outputData = outputBuffers_[0]->data(outputIndex);
        auto *inputPtr = reinterpret_cast<int8_t *>(inputData.first);
        auto *outputPtr = reinterpret_cast<int8_t *>(outputData.first);
        if (inputPtr == nullptr || outputPtr == nullptr) return {};

        const float inputScale = std::pow(2.0f, static_cast<float>(tensorFixPoint(inputTensor)));
        std::fill(inputPtr, inputPtr + inputElements, static_cast<int8_t>(0));
        for (int i = 0; i < BeatPreprocessor::kModelInputSamples; ++i)
        {
            const int quantized = static_cast<int>(std::lround(input[i] * inputScale));
            inputPtr[i] = static_cast<int8_t>(std::clamp(quantized, -128, 127));
        }

        const auto job = runner_->execute_async(inputBuffers_, outputBuffers_);
        runner_->wait(static_cast<int>(job.first), -1);

        const float outputScale = std::pow(2.0f, static_cast<float>(tensorFixPoint(outputTensor)));
        QVector<float> logits;
        logits.reserve(5);
        for (int i = 0; i < 5; ++i)
        {
            logits.append(static_cast<float>(outputPtr[i]) / std::max(1.0f, outputScale));
        }
        AiBeatResult result = makeResultFromProbabilities(softmax(logits));
        result.runtime = runtimeName();
        return result;
    }

private:
    bool loaded_ = false;
    std::unique_ptr<xir::Graph> graph_;
    std::unique_ptr<vart::RunnerExt> runner_;
    std::vector<vart::TensorBuffer *> inputBuffers_;
    std::vector<vart::TensorBuffer *> outputBuffers_;
};
#endif
}

QString classifierBackendName(const ClassifierBackend backend)
{
    switch (backend)
    {
    case ClassifierBackend::Rtl: return "RTL";
    case ClassifierBackend::Cpu: return "CPU";
    case ClassifierBackend::Dpu: return "DPU";
    }
    return "UNKNOWN";
}

bool classifierBackendCompiled(const ClassifierBackend backend)
{
    switch (backend)
    {
    case ClassifierBackend::Cpu:
        return true;
    case ClassifierBackend::Rtl:
#if defined(Q_OS_LINUX) && (defined(__aarch64__) || defined(__arm__))
        return true;
#else
        return false;
#endif
    case ClassifierBackend::Dpu:
#ifdef ECG_ENABLE_VITIS_AI
        return true;
#else
        return false;
#endif
    }
    return false;
}

ClassifierBackend defaultHeartbeatClassifierBackend()
{
    const QString requested = qEnvironmentVariable("ECG_BACKEND").trimmed().toLower();
    if (requested == "rtl") return ClassifierBackend::Rtl;
    if (requested == "cpu") return ClassifierBackend::Cpu;
    if (requested == "dpu") return ClassifierBackend::Dpu;
#ifdef ECG_ENABLE_VITIS_AI
    return ClassifierBackend::Dpu;
#else
    return ClassifierBackend::Cpu;
#endif
}

std::shared_ptr<IHeartbeatClassifier> createHeartbeatClassifier(const ClassifierBackend backend)
{
    switch (backend)
    {
    case ClassifierBackend::Cpu:
        return std::make_shared<CnnPythonClassifier>();
    case ClassifierBackend::Rtl:
#ifdef Q_OS_LINUX
        return std::make_shared<RtlPlHeartbeatClassifier>();
#else
        return {};
#endif
    case ClassifierBackend::Dpu:
#ifdef ECG_ENABLE_VITIS_AI
        return std::make_shared<DpuXmodelHeartbeatClassifier>();
#else
        return {};
#endif
    }
    return {};
}

std::shared_ptr<IHeartbeatClassifier> createDefaultHeartbeatClassifier()
{
    return createHeartbeatClassifier(defaultHeartbeatClassifierBackend());
}
