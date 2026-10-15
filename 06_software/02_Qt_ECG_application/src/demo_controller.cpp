#include "demo_controller.h"

#include "ai/heartbeat_classifier.h"

#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QFileDialog>
#include <QFileInfo>
#include <QMessageBox>

#include <algorithm>

namespace
{
constexpr int kTickMs = 40;
constexpr int kSamplesPerTick = 5; // 125 Hz * 40 ms
}

DemoController::DemoController(QObject *parent)
    : QObject(parent),
      view_(new DemoWindow()),
      emulator_(&library_)
{
    QString dataError;
    const QString dataDirectory = resolveDataDirectory();
    if (!library_.load(dataDirectory, &dataError))
    {
        view_->showStatus(dataError, true);
        running_ = false;
    }
    else
    {
        view_->showStatus(library_.summary());
    }

    connect(&timer_, &QTimer::timeout, this, &DemoController::tick);
    connect(view_, &DemoWindow::modeChanged, this, &DemoController::setMode);
    connect(view_, &DemoWindow::bpmChanged, this, &DemoController::setBpm);
    connect(view_, &DemoWindow::noiseChanged, this, &DemoController::setNoise);
    connect(view_, &DemoWindow::pauseRequested, this, &DemoController::pauseOrResume);
    connect(view_, &DemoWindow::resetRequested, this, &DemoController::reset);
    connect(view_, &DemoWindow::exportRequested, this, &DemoController::exportVisible);
    connect(view_, &DemoWindow::summaryRequested, this, &DemoController::showSummary);
    connect(view_, &DemoWindow::reviewStateChanged, this, &DemoController::setReviewState);
    connect(view_, &DemoWindow::backendChanged, this, &DemoController::setBackend);

    view_->setBackendAvailability(
        classifierBackendCompiled(ClassifierBackend::Rtl),
        classifierBackendCompiled(ClassifierBackend::Cpu),
        classifierBackendCompiled(ClassifierBackend::Dpu));

    // Nguon nhip duoc noi truoc khi chon backend, de dong trang thai dau tien
    // tren thanh status noi ve nguon du lieu chu khong bi backend ghi de.
    connectSerialSource();

    const ClassifierBackend requestedBackend = defaultHeartbeatClassifierBackend();
    QString backendError;
    if (!activateBackend(requestedBackend, &backendError))
    {
        // Keep the GUI usable if a hardware backend is not ready at startup.
        // The user can prepare the backend and select it again without
        // rebuilding the application.
        if (requestedBackend != ClassifierBackend::Cpu &&
            activateBackend(ClassifierBackend::Cpu, nullptr))
        {
            view_->showStatus(QString("%1 Falling back to CPU.").arg(backendError), true);
        }
        else
        {
            view_->showStatus(backendError, true);
        }
    }

    setMode(0);
    timer_.setInterval(kTickMs);

}

void DemoController::syncSerialStream()
{
    if (!serial_.isOpen()) return;
    if (running_) serial_.sendStart(); else serial_.sendStop();
    qInfo().noquote() << QString("[SERIAL] gui %1 (running=%2)")
                             .arg(running_ ? "START" : "STOP")
                             .arg(running_ ? "true" : "false");
}

void DemoController::show()
{
    view_->show();
    if (library_.isLoaded())
    {
        running_ = true;
        view_->setLiveState(true);
        timer_.start();
    }
    // Dong bo o day chu khong phai trong constructor: running_ chi thanh true
    // tai day. Dong bo som hon se gui STOP roi khong bao gio gui START, va
    // ESP32 se dung im trong khi giao dien hien LIVE.
    syncSerialStream();
}

QString DemoController::resolveDataDirectory() const
{
    const QString envPath = qEnvironmentVariable("ECG_DATA_DIR").trimmed();
    if (!envPath.isEmpty() && QDir(envPath).exists())
    {
        return QDir(envPath).absolutePath();
    }

    const QString appDir = QCoreApplication::applicationDirPath();
    const QStringList candidates = {
        appDir + "/data",
        appDir + "/../data",
        QDir::currentPath() + "/data",
        QDir::currentPath() + "/../data"};
    for (const QString &candidate : candidates)
    {
        if (QFileInfo::exists(candidate + "/sampleN.txt"))
        {
            return QDir(candidate).absolutePath();
        }
    }
    return QDir(candidates.first()).absolutePath();
}

QString DemoController::resolveModel() const
{
    const QString envPath = qEnvironmentVariable("ECG_XMODEL_PATH").trimmed();
    if (!envPath.isEmpty()) return envPath;

    const QString appDir = QCoreApplication::applicationDirPath();
    const QStringList candidates = {
        appDir + "/models/ecg_1dcnn_2d_dpu.xmodel",
        appDir + "/../models/ecg_1dcnn_2d_dpu.xmodel",
        QDir::currentPath() + "/models/ecg_1dcnn_2d_dpu.xmodel"};
    for (const QString &candidate : candidates)
    {
        if (QFileInfo::exists(candidate)) return QFileInfo(candidate).absoluteFilePath();
    }
    return candidates.first();
}

bool DemoController::activateBackend(const ClassifierBackend backend, QString *errorMessage)
{
    // Stop the outgoing engine BEFORE the incoming one is created, so two are
    // never live at the same time. The CPU backend owns a python3 worker: left
    // running while RTL is the selected interface it would hold a core and
    // perturb the accelerator's latency, which is exactly what the RTL mode is
    // being measured for. Destroying the classifier sends QUIT to that worker
    // and closes its stdin, so it exits even if it ignores the request.
    const ClassifierBackend previous = classifierBackend_;
    const bool hadClassifier = static_cast<bool>(classifier_);
    classifier_.reset();

    auto candidate = createHeartbeatClassifier(backend);
    QString loadMessage;
    const bool ready = candidate && candidate->load(resolveModel(), &loadMessage);

    if (!ready)
    {
        if (errorMessage != nullptr)
        {
            if (!candidate)
            {
                *errorMessage = QString("%1 backend is not available in this build.")
                                    .arg(classifierBackendName(backend));
            }
            else
            {
                *errorMessage = loadMessage.isEmpty()
                                    ? QString("%1 backend could not be initialized.")
                                          .arg(classifierBackendName(backend))
                                    : loadMessage;
            }
        }
        // The previous engine was released above, so a failed switch must bring
        // it back explicitly; otherwise the app would be left with no
        // classifier at all, which the old ordering never allowed.
        if (hadClassifier && previous != backend)
        {
            auto restored = createHeartbeatClassifier(previous);
            if (restored && restored->load(resolveModel(), nullptr))
            {
                classifier_ = std::move(restored);
                classifierBackend_ = previous;
            }
        }
        return false;
    }

    classifier_ = std::move(candidate);
    classifierBackend_ = backend;
    view_->setBackendSelection(static_cast<int>(backend));
    view_->setRuntimeStatus(
        QString("%1 — %2").arg(classifier_->runtimeName(), classifier_->statusText()),
        true);
    return true;
}

void DemoController::setBackend(const int backendIndex)
{
    if (backendIndex < static_cast<int>(ClassifierBackend::Rtl) ||
        backendIndex > static_cast<int>(ClassifierBackend::Dpu))
    {
        return;
    }

    const auto requested = static_cast<ClassifierBackend>(backendIndex);
    if (requested == classifierBackend_) return;

    const bool wasRunning = running_;
    timer_.stop();

    QString error;
    if (!activateBackend(requested, &error))
    {
        view_->setBackendSelection(static_cast<int>(classifierBackend_));
        view_->showStatus(error, true);
        if (wasRunning) timer_.start();
        return;
    }

    // A backend change starts a clean classification session. This prevents
    // Recent Beats / Abnormal Review from mixing RTL, CPU and DPU results.
    resetSession(wasRunning);
    view_->showStatus(QString());
}

void DemoController::tick()
{
    if (!running_ || !library_.isLoaded()) return;

    const SignalBlock block = emulator_.nextSamples(kSamplesPerTick);
    const QVector<double> processed = displayProcessor_.process(block.raw);
    signalBuffer_.append(block.raw, processed);

    for (const BeatEvent &event : block.events)
    {
        // A newly observed beat is the "after" beat for any abnormal event
        // that was waiting for three-beat review context. Attach it before
        // processing the new event itself so consecutive abnormal beats are
        // handled correctly.
        attachFollowingBeat(event);

        const FixedBeat &beat = beatFor(event.classIndex);
        const qint64 markerSample = event.rSample + beat.displayRIndex;
        const double markerValue = beat.displayWave.value(beat.displayRIndex, 0.0);
        markers_.append({markerSample, markerValue, -1, 0.0f});
        processBeatEvent(event);
        observedBeats_.append(observedBeat(event));
        while (observedBeats_.size() > 8) observedBeats_.removeFirst();
        updateHeartRate(event);
    }

    // Context is frozen only after the complete following beat has entered the
    // real raw/processed signal buffer. This guarantees the review image is
    // previous beat -> problem beat -> following beat, not a clean template.
    finalizeContextCaptures();

    if (!block.events.isEmpty())
    {
        view_->updateReviewData(history_, eventCounts_);
    }

    const qint64 keepAfter = std::max<qint64>(0, signalBuffer_.totalSamples() - SignalBuffer::kMaxFullSamples);
    while (!markers_.isEmpty() && markers_.first().sample < keepAfter)
    {
        markers_.removeFirst();
    }
    while (!beatHighlights_.isEmpty() && beatHighlights_.first().endSample <= keepAfter)
    {
        beatHighlights_.removeFirst();
    }

    view_->setSampleCount(signalBuffer_.totalSamples());
    refreshPlot();
}

const FixedBeat &DemoController::beatFor(const int classIndex) const
{
    // Khi ESP32 da gui nhip cho lop nay thi dung nhip do -- ca cho dang song
    // hien thi lan cho dau vao phan loai. data/ chi con la ban du phong.
    if (emulator_.hasExternalBeat(classIndex))
    {
        return emulator_.externalBeat(classIndex);
    }
    return library_.beat(classIndex);
}

void DemoController::connectSerialSource()
{
    connect(&serial_, &SerialBeatSource::beatReceived, this, &DemoController::onSerialBeat);
    connect(&serial_, &SerialBeatSource::statusLine, this, &DemoController::onSerialStatus);
    connect(&serial_, &SerialBeatSource::disconnected, this, &DemoController::onSerialDisconnected);

    // Cho phep chi dinh cong bang bien moi truong; neu khong thi thu lan luot
    // cac ten thong dung. Khong mo duoc thi chay tiep bang data/, khong bao loi
    // om som: nguon du phong la mot che do hop le chu khong phai su co.
    // Neu nguoi dung chi dinh cong thi chi thu dung cong do. Roi sang cong khac
    // khi cong duoc chi dinh hong la hanh vi de gay hieu nham: se khong con
    // cach nao buoc ung dung chay bang ban du phong de doi chieu.
    const QString override = qEnvironmentVariable("ECG_SERIAL_PORT").trimmed();
    const QStringList candidates = override.isEmpty()
                                       ? SerialBeatSource::defaultPortCandidates()
                                       : QStringList{override};

    for (const QString &port : candidates)
    {
        QString error;
        if (serial_.open(port, &error))
        {
            serial_.sendClass(emulator_.mode());
            serial_.sendBpm(emulator_.bpm());
            view_->showStatus(QString("ECG source: ESP32 tren %1").arg(port));
            return;
        }
    }
    qInfo().noquote() << "[SERIAL] khong mo duoc cong nao, dung ban du phong data/";
    view_->showStatus("ECG source: du phong tu data/ (khong thay ESP32)");
}

void DemoController::onSerialBeat(const int classIndex, const double bpm,
                                  const QVector<qint16> &samples)
{
    Q_UNUSED(bpm);
    const bool first = !emulator_.hasExternalBeat(classIndex);
    emulator_.setExternalBeat(classIndex, FixedBeatLibrary::makeBeatFromQ88(classIndex, samples));

    // Bao mot lan cho moi lop. Du lieu ESP32 hien trung het data/, nen neu
    // khong co dong nay thi khong the phan biet duoc nhip dang den tu thiet bi
    // hay tu ban du phong -- ket qua hien thi giong nhau ca hai duong.
    if (first && emulator_.hasExternalBeat(classIndex))
    {
        qInfo().noquote() << QString("[SERIAL] nhan nhip lop %1 tu ESP32, %2 mau")
                                 .arg(ecgClassShortName(classIndex))
                                 .arg(samples.size());
    }
}

void DemoController::onSerialStatus(const QString &text)
{
    view_->showStatus(QString("ESP32: %1").arg(text));
}

void DemoController::onSerialDisconnected(const QString &reason)
{
    // Giu lai cac nhip da nhan duoc: chung van dung hon nhip mau trong data/,
    // va rut chung ra giua chung se lam dang song nhay mot cai khong can thiet.
    view_->showStatus(QString("ESP32 mat ket noi (%1); dang dung nhip da nhan").arg(reason), true);
}

void DemoController::setMode(const int classIndex)
{
    emulator_.setMode(classIndex);
    serial_.sendClass(classIndex);
    const FixedBeat &beat = beatFor(classIndex);
    view_->setModeInfo(classIndex, beat.sourceFile, rhythmDescription(classIndex), defaultBpm(classIndex));
    resetSession(running_);
}

void DemoController::setBpm(const double bpm)
{
    emulator_.setBpm(bpm);
    serial_.sendBpm(bpm);
    view_->setHeartRate(bpm);
}

void DemoController::setNoise(const double noise)
{
    emulator_.setNoise(noise);
}

void DemoController::pauseOrResume()
{
    if (!library_.isLoaded()) return;
    running_ = !running_;
    if (running_) timer_.start(); else timer_.stop();
    syncSerialStream();
    view_->setLiveState(running_);
    view_->updateReviewData(history_, eventCounts_);
}

void DemoController::reset()
{
    resetSession(running_);
}

void DemoController::resetSession(const bool keepRunning)
{
    const bool wasRunning = keepRunning;
    timer_.stop();
    emulator_.reset();
    displayProcessor_.reset();
    signalBuffer_.clear();
    markers_.clear();
    beatHighlights_.clear();
    eventCounts_.fill(0, 5);
    history_.clear();
    observedBeats_.clear();
    pendingCaptures_.clear();
    recentRrSeconds_.clear();
    lastRsample_ = -1;
    beatCount_ = 0;
    predictedCount_ = 0;
    correctCount_ = 0;
    view_->clearSession();
    view_->setClassCounts(eventCounts_);
    view_->updateReviewData(history_, eventCounts_);
    view_->setHeartRate(emulator_.bpm());
    refreshPlot();
    running_ = wasRunning && library_.isLoaded();
    view_->setLiveState(running_);
    if (running_) timer_.start();
}

void DemoController::processBeatEvent(const BeatEvent &event)
{
    ++beatCount_;
    if (event.classIndex >= 0 && event.classIndex < eventCounts_.size())
    {
        ++eventCounts_[event.classIndex];
        view_->setClassCounts(eventCounts_);
    }

    const double timeSeconds = static_cast<double>(event.rSample) / RhythmEmulator::kSampleRate;
    if (!classifier_ || !classifier_->isLoaded())
    {
        view_->setExpectedBeat(beatCount_, event.classIndex, timeSeconds);
        return;
    }

    AiBeatResult result = classifier_->classify187(beatFor(event.classIndex).modelInput);
    if (!result.valid)
    {
        view_->setExpectedBeat(beatCount_, event.classIndex, timeSeconds);
        view_->showStatus(
            QString("%1 inference returned no valid 5-class output.")
                .arg(classifierBackendName(classifierBackend_)),
            true);
        return;
    }

    result.beatIndex = beatCount_;
    result.timeSeconds = timeSeconds;

    HistoryRecord record;
    record.result = result;
    record.problemClassIndex = event.classIndex;
    history_.append(record);
    const int historyIndex = history_.size() - 1;

    if (result.classIndex > 0 && !observedBeats_.isEmpty())
    {
        PendingContextCapture pending;
        pending.historyIndex = historyIndex;
        pending.previous = observedBeats_.last();
        pending.problem = observedBeat(event);
        pendingCaptures_.append(pending);
    }

    ++predictedCount_;
    if (result.classIndex == event.classIndex) ++correctCount_;
    const qint64 markerSample = event.rSample + beatFor(event.classIndex).displayRIndex;
    if (!markers_.isEmpty() && markers_.last().sample == markerSample)
    {
        markers_.last().classIndex = result.classIndex;
        markers_.last().confidence = result.confidence;
    }

    // Highlight the complete abnormal-beat region around the displayed R peak.
    //
    // The fixed demo templates are not phase-aligned in the same way:
    //   S/Q have displayRIndex == 0, F is approximately 1, while V has a
    //   genuine pre-R segment (currently 23 samples).  Using event.rSample as
    //   the highlight start therefore made S/F/Q begin at the R spike while V
    //   looked correct.  Keep the waveform generation untouched, but give all
    //   abnormal classes the same pre-R context that is already present in the
    //   most complete template.  The post-R end remains class-specific.
    if (result.classIndex > 0)
    {
        const FixedBeat &displayBeat = beatFor(event.classIndex);
        const qint64 markerSample = event.rSample + displayBeat.displayRIndex;

        int commonPreRSamples = 0;
        for (int classIndex = 0; classIndex < FixedBeatLibrary::kClassCount; ++classIndex)
        {
            commonPreRSamples = std::max(commonPreRSamples,
                                         beatFor(classIndex).displayRIndex);
        }

        const int postRSamples = std::max(1,
                                          static_cast<int>(displayBeat.displayWave.size()) -
                                              displayBeat.displayRIndex);
        const qint64 startSample = markerSample - commonPreRSamples;
        const qint64 endSample = markerSample + postRSamples;
        if (endSample > startSample)
        {
            beatHighlights_.append({startSample, endSample, result.classIndex, result.confidence});
        }
    }

    view_->setPrediction(result, event.classIndex, correctCount_, predictedCount_);
}

DemoController::ObservedBeat DemoController::observedBeat(const BeatEvent &event) const
{
    const FixedBeat &beat = beatFor(event.classIndex);
    ObservedBeat observed;
    observed.startSample = event.rSample;
    observed.rSample = event.rSample + beat.displayRIndex;
    observed.classIndex = event.classIndex;
    return observed;
}

void DemoController::attachFollowingBeat(const BeatEvent &event)
{
    const ObservedBeat next = observedBeat(event);
    for (PendingContextCapture &pending : pendingCaptures_)
    {
        if (pending.hasNext || next.startSample <= pending.problem.startSample)
        {
            continue;
        }

        pending.next = next;
        pending.hasNext = true;

        // Crop by R-R context so the review image contains exactly the
        // previous, selected, and following complexes without carrying the
        // full template tail into a possible fourth beat. The crop extends
        // half of the adjacent R-R interval before the previous R and half of
        // the selected->following R-R interval after the following R.
        const qint64 rrBeforeToSelected = std::max<qint64>(1, pending.problem.rSample - pending.previous.rSample);
        const qint64 rrSelectedToAfter = std::max<qint64>(1, pending.next.rSample - pending.problem.rSample);
        pending.startSample = std::max<qint64>(0, pending.previous.rSample - rrBeforeToSelected / 2);
        pending.endSample = pending.next.rSample + rrSelectedToAfter / 2;
    }
}

void DemoController::finalizeContextCaptures()
{
    bool changed = false;
    for (int index = pendingCaptures_.size() - 1; index >= 0; --index)
    {
        const PendingContextCapture &pending = pendingCaptures_[index];
        if (!pending.hasNext || signalBuffer_.totalSamples() < pending.endSample)
        {
            continue;
        }

        if (pending.historyIndex < 0 || pending.historyIndex >= history_.size())
        {
            pendingCaptures_.removeAt(index);
            continue;
        }

        QVector<double> raw;
        QVector<double> processed;
        const qint64 captureStart = pending.startSample;
        if (!signalBuffer_.extractRange(captureStart,
                                        pending.endSample,
                                        &raw,
                                        &processed))
        {
            // The full buffer normally retains ten minutes, so a just-completed
            // three-beat context should always be present. If not, drop this
            // pending capture rather than substituting a clean template.
            pendingCaptures_.removeAt(index);
            continue;
        }

        HistoryRecord &record = history_[pending.historyIndex];
        record.rawSignal = raw;
        record.processedSignal = processed;
        record.previousRIndex = static_cast<int>(pending.previous.rSample - captureStart);
        record.problemRIndex = static_cast<int>(pending.problem.rSample - captureStart);
        record.nextRIndex = static_cast<int>(pending.next.rSample - captureStart);
        record.previousClassIndex = pending.previous.classIndex;
        record.problemClassIndex = pending.problem.classIndex;
        record.nextClassIndex = pending.next.classIndex;
        record.contextReady = !raw.isEmpty() && raw.size() == processed.size();

        pendingCaptures_.removeAt(index);
        changed = true;
    }

    if (changed)
    {
        view_->updateReviewData(history_, eventCounts_);
    }
}

void DemoController::updateHeartRate(const BeatEvent &event)
{
    if (lastRsample_ >= 0)
    {
        const double rr = static_cast<double>(event.rSample - lastRsample_) / RhythmEmulator::kSampleRate;
        if (rr >= 0.30 && rr <= 2.0)
        {
            recentRrSeconds_.append(rr);
            while (recentRrSeconds_.size() > 6) recentRrSeconds_.removeFirst();
            QVector<double> sorted = recentRrSeconds_;
            std::sort(sorted.begin(), sorted.end());
            const int n = sorted.size();
            const double median = n % 2 == 0 ? 0.5 * (sorted[n / 2 - 1] + sorted[n / 2]) : sorted[n / 2];
            view_->setHeartRate(60.0 / median);
        }
    }
    lastRsample_ = event.rSample;
}

void DemoController::refreshPlot()
{
    const QVector<double> keys = signalBuffer_.sweepKeys();
    const QVector<double> values = signalBuffer_.sweepValues(true, 10);
    const double cursorKey = static_cast<double>(signalBuffer_.cursor()) / SignalBuffer::kSampleRate;
    const bool showCursor = true;

    QVector<double> rKeys;
    QVector<double> rValues;
    QVector<int> rClasses;
    QVector<float> rConfidences;
    const qint64 total = signalBuffer_.totalSamples();
    const qint64 visibleStart = std::max<qint64>(0, total - SignalBuffer::kVisibleSamples);

    for (const Marker &marker : markers_)
    {
        if (marker.sample >= total) continue;
        if (marker.sample < visibleStart) continue;
        rKeys.append(static_cast<double>(marker.sample % SignalBuffer::kVisibleSamples) / SignalBuffer::kSampleRate);
        rValues.append(marker.value);
        rClasses.append(marker.classIndex);
        rConfidences.append(marker.confidence);
    }

    // Build a one-to-one class mask for the circular sweep buffer. This avoids
    // inferring a colored interval from marker age (the old implementation
    // painted up to 1.25 s after R). Each painted sample now belongs to the
    // exact displayed morphology of the AI-classified beat.
    QVector<int> sampleClasses(keys.size(), -1);
    QVector<float> sampleConfidences(keys.size(), 0.0f);
    for (const BeatHighlight &highlight : beatHighlights_)
    {
        if (highlight.classIndex <= 0 || highlight.endSample <= visibleStart || highlight.startSample >= total)
        {
            continue;
        }

        const qint64 start = std::max(highlight.startSample, visibleStart);
        const qint64 stop = std::min(highlight.endSample, total);
        for (qint64 sample = start; sample < stop; ++sample)
        {
            const int index = static_cast<int>(sample % SignalBuffer::kVisibleSamples);
            if (index < 0 || index >= sampleClasses.size()) continue;

            // Overlap is unusual in this demo, but if it happens, retain the
            // classification with the greater confidence for that sample.
            if (sampleClasses[index] < 0 || highlight.confidence >= sampleConfidences[index])
            {
                sampleClasses[index] = highlight.classIndex;
                sampleConfidences[index] = highlight.confidence;
            }
        }
    }

    view_->setPlotData(keys,
                       values,
                       rKeys,
                       rValues,
                       rClasses,
                       rConfidences,
                       sampleClasses,
                       sampleConfidences,
                       cursorKey,
                       showCursor);
}

void DemoController::exportVisible()
{
    const QString defaultName = QString("ecg_%1_visible.csv").arg(ecgClassShortName(emulator_.mode()));
    const QString path = QFileDialog::getSaveFileName(view_,
                                                      "Export visible ECG window",
                                                      QDir::currentPath() + "/" + defaultName,
                                                      "CSV files (*.csv)");
    if (path.isEmpty()) return;

    QString error;
    if (!signalBuffer_.exportVisibleCsv(path, &error))
    {
        QMessageBox::critical(view_, "Export failed", error);
        return;
    }
    view_->showStatus(QString("Exported visible 10 s window to %1").arg(path));
}

void DemoController::showSummary()
{
    view_->showSummary(history_, eventCounts_);
}

void DemoController::setReviewState(const int beatIndex, const bool reviewed)
{
    for (HistoryRecord &record : history_)
    {
        if (record.result.beatIndex == beatIndex)
        {
            record.reviewed = reviewed;
            break;
        }
    }
    view_->updateReviewData(history_, eventCounts_);
}

QString DemoController::rhythmDescription(const int classIndex) const
{
    switch (classIndex)
    {
    case 1: return "Rhythm with premature supraventricular ectopic beats";
    case 2: return "Rhythm with premature ventricular ectopic beats";
    case 3: return "Rhythm with intermittent fusion beats";
    case 4: return "Rhythm with unclassifiable beats";
    default: return "Regular sinus rhythm";
    }
}

int DemoController::defaultBpm(const int classIndex) const
{
    static const int values[5] = {72, 76, 72, 72, 74};
    return values[std::clamp(classIndex, 0, 4)];
}
