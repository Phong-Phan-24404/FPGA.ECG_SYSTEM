#pragma once

#include "ecg_types.h"
#include "qcustomplot.h"

#include <QMainWindow>

class AbnormalReviewWindow;
class QButtonGroup;
class QComboBox;
class QLabel;
class QPushButton;
class QSlider;
class QSpinBox;
class QTableWidget;
class QTimer;

class DemoWindow final : public QMainWindow
{
    Q_OBJECT

public:
    enum class RenderMode { LineAndPoints };
    enum class DisplayMode { Sweep };

    explicit DemoWindow(QWidget *parent = nullptr);

    RenderMode renderMode() const;
    DisplayMode displayMode() const;
    bool showProcessedSignal() const;

    void setPlotData(const QVector<double> &keys,
                     const QVector<double> &values,
                     const QVector<double> &rKeys,
                     const QVector<double> &rValues,
                     const QVector<int> &rClasses,
                     const QVector<float> &rConfidences,
                     const QVector<int> &sampleClasses,
                     const QVector<float> &sampleConfidences,
                     double cursorKey,
                     bool showCursor);
    void clearSession();
    void setRuntimeStatus(const QString &status, bool ready);
    void setBackendSelection(int backendIndex);
    void setBackendAvailability(bool rtlAvailable, bool cpuAvailable, bool dpuAvailable);
    void setLiveState(bool running);
    void setModeInfo(int classIndex, const QString &sourceFile, const QString &description, int defaultBpm);
    void setHeartRate(double bpm);
    void setSampleCount(qint64 count);
    void setExpectedBeat(int beatIndex, int truthClass, double timeSeconds);
    void setPrediction(const AiBeatResult &result, int truthClass, int correct, int predictedTotal);
    void setClassCounts(const QVector<int> &eventCounts);
    void showStatus(const QString &text, bool warning = false);
    void showSummary(const QVector<HistoryRecord> &history, const QVector<int> &eventCounts);
    void updateReviewData(const QVector<HistoryRecord> &history, const QVector<int> &eventCounts);

signals:
    void modeChanged(int classIndex);
    void bpmChanged(double bpm);
    void noiseChanged(double noise);
    void pauseRequested();
    void resetRequested();
    void exportRequested();
    void summaryRequested();
    void reviewStateChanged(int beatIndex, bool reviewed);
    void backendChanged(int backendIndex);
    void emergencyRequested();

private:
    void configurePlot();
    void applyRenderMode();
    void updateClock();
    // Danh gia lai trang thai bao dong. Tach rieng vi no duoc goi ca khi
    // co nhip moi lan khi nguoi dung doi nguong.
    void refreshEmergencyState();
    QString classColor(int classIndex) const;

    QCustomPlot *plot_ = nullptr;
    QCPItemLine *cursorLine_ = nullptr;
    QButtonGroup *classButtons_ = nullptr;
    QButtonGroup *backendButtons_ = nullptr;
    QComboBox *displayFilterCombo_ = nullptr;
    QSlider *bpmSlider_ = nullptr;
    QSlider *noiseSlider_ = nullptr;
    QPushButton *pauseButton_ = nullptr;
    QPushButton *summaryButton_ = nullptr;
    QPushButton *emergencyButton_ = nullptr;
    QSpinBox *emergencyThresholdSpin_ = nullptr;
    // So nhip S/V/F da thu duoc trong phien. Luu lai de doi nguong
    // cung danh gia duoc ngay ma khong phai cho nhip tiep theo.
    int criticalCount_ = 0;
    QLabel *liveLabel_ = nullptr;
    QLabel *clockLabel_ = nullptr;
    QLabel *bpmLabel_ = nullptr;
    QLabel *noiseLabel_ = nullptr;
    QLabel *classCodeLabel_ = nullptr;
    QLabel *classNameLabel_ = nullptr;
    QLabel *rhythmLabel_ = nullptr;
    QLabel *runtimeLabel_ = nullptr;
    QLabel *predictionCodeLabel_ = nullptr;
    QLabel *predictionLabel_ = nullptr;
    QLabel *confidenceLabel_ = nullptr;
    QLabel *truthLabel_ = nullptr;
    QLabel *agreementLabel_ = nullptr;
    QLabel *countLabel_ = nullptr;
    QLabel *sampleCountLabel_ = nullptr;
    QLabel *statusLabel_ = nullptr;
    QTableWidget *historyTable_ = nullptr;
    QTimer *clockTimer_ = nullptr;
    AbnormalReviewWindow *reviewWindow_ = nullptr;
};
