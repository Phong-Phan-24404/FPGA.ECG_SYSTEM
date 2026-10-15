#pragma once

#include "demo_window.h"
#include "ai/heartbeat_classifier.h"
#include "display_processor.h"
#include "fixed_beat_library.h"
#include "rhythm_emulator.h"
#include "serial_beat_source.h"
#include "signal_buffer.h"

#include <QObject>
#include <QTimer>
#include <QVector>

#include <memory>


class DemoController final : public QObject
{
    Q_OBJECT

public:
    explicit DemoController(QObject *parent = nullptr);
    void show();

private slots:
    void tick();
    void setMode(int classIndex);
    void setBpm(double bpm);
    void setNoise(double noise);
    void pauseOrResume();
    void reset();
    void exportVisible();
    void showSummary();
    void setReviewState(int beatIndex, bool reviewed);
    void setBackend(int backendIndex);
    // Nhip that tu ESP32: thay noi dung nhip cua lop tuong ung.
    void onSerialBeat(int classIndex, double bpm, const QVector<qint16> &samples);
    void onSerialStatus(const QString &text);
    void onSerialDisconnected(const QString &reason);
    void refreshPlot();

private:
    struct Marker
    {
        qint64 sample = 0;
        double value = 0.0;
        int classIndex = -1;
        float confidence = 0.0f;
    };

    // Absolute sample interval belonging to one beat that the AI classified as
    // abnormal. endSample is exclusive. Keeping the interval in absolute
    // samples lets the controller repaint the correct historical morphology
    // even though the bedside-style plot uses a circular sweep buffer.
    struct BeatHighlight
    {
        qint64 startSample = 0;
        qint64 endSample = 0;
        int classIndex = -1;
        float confidence = 0.0f;
    };

    struct ObservedBeat
    {
        qint64 startSample = 0;
        qint64 rSample = 0;
        int classIndex = 0;
    };

    struct PendingContextCapture
    {
        int historyIndex = -1;
        ObservedBeat previous;
        ObservedBeat problem;
        ObservedBeat next;
        bool hasNext = false;
        qint64 startSample = 0;
        qint64 endSample = 0;
    };

    QString resolveDataDirectory() const;
    QString resolveModel() const;
    bool activateBackend(ClassifierBackend backend, QString *errorMessage = nullptr);
    // Nhip dung cho hien thi va phan loai: uu tien nguon ngoai, roi den data/.
    const FixedBeat &beatFor(int classIndex) const;
    void connectSerialSource();
    // Gui START hoac STOP sang ESP32 cho khop voi trang thai chay hien tai.
    void syncSerialStream();
    void resetSession(bool keepRunning);
    void processBeatEvent(const BeatEvent &event);
    ObservedBeat observedBeat(const BeatEvent &event) const;
    void attachFollowingBeat(const BeatEvent &event);
    void finalizeContextCaptures();
    void updateHeartRate(const BeatEvent &event);
    QString rhythmDescription(int classIndex) const;
    int defaultBpm(int classIndex) const;

    DemoWindow *view_ = nullptr;
    FixedBeatLibrary library_;
    RhythmEmulator emulator_;
    SerialBeatSource serial_;
    DisplayProcessor displayProcessor_;
    SignalBuffer signalBuffer_;
    std::shared_ptr<IHeartbeatClassifier> classifier_;
    ClassifierBackend classifierBackend_ = ClassifierBackend::Cpu;
    QTimer timer_;
    QVector<Marker> markers_;
    QVector<BeatHighlight> beatHighlights_;
    QVector<int> eventCounts_{0, 0, 0, 0, 0};
    QVector<HistoryRecord> history_;
    QVector<ObservedBeat> observedBeats_;
    QVector<PendingContextCapture> pendingCaptures_;
    QVector<double> recentRrSeconds_;
    qint64 lastRsample_ = -1;
    int beatCount_ = 0;
    int predictedCount_ = 0;
    int correctCount_ = 0;
    bool running_ = false;
};
