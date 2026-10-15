#pragma once

#include "ecg_types.h"
#include "qcustomplot.h"

#include <QDialog>
#include <QRect>
#include <QVector>

class QComboBox;
class QGroupBox;
class QHBoxLayout;
class QLabel;
class QPushButton;
class QProgressBar;
class QResizeEvent;
class QKeyEvent;
class QTableWidget;
class QToolButton;
class QVBoxLayout;
class QWidget;

class AbnormalReviewWindow final : public QDialog
{
    Q_OBJECT

public:
    explicit AbnormalReviewWindow(QWidget *parent = nullptr);

    void setData(const QVector<HistoryRecord> &history,
                 const QVector<int> &eventCounts,
                 bool monitoringLive);
    void selectBeat(int beatIndex);

signals:
    void reviewStateChanged(int beatIndex, bool reviewed);

protected:
    void resizeEvent(QResizeEvent *event) override;
    void keyPressEvent(QKeyEvent *event) override;

private:
    void rebuildTable(bool refreshSelected = true);
    void updateSummaryCards();
    void updateSelectedRecord();
    void updatePlot(const HistoryRecord *record);
    void updateProbabilities(const HistoryRecord *record);
    void updateNewEventBadge();
    void updateSignalHint();
    void fitPlotToSelectedEvent();
    void toggleExpandedMode();
    void toggleFocusMode();
    void setFocusMode(bool enabled);
    void setAiDetailsVisible(bool visible);
    void applyResponsiveScale(bool force = false);
    void refreshStyleSheet();
    void refreshPlotScale();
    int selectedHistoryIndex() const;
    QString classColor(int classIndex) const;
    QString formatSessionTime(double seconds) const;

    QVector<HistoryRecord> history_;
    QVector<int> eventCounts_{0, 0, 0, 0, 0};
    QVector<int> filteredHistoryIndices_;

    QVBoxLayout *rootLayout_ = nullptr;
    QHBoxLayout *bodyLayout_ = nullptr;
    QWidget *headerWidget_ = nullptr;
    QLabel *titleLabel_ = nullptr;
    QLabel *liveStateLabel_ = nullptr;
    QPushButton *expandButton_ = nullptr;
    QWidget *summaryStrip_ = nullptr;
    QLabel *totalBeatsValue_ = nullptr;
    QLabel *abnormalValue_ = nullptr;
    QLabel *classValues_[4] = {nullptr, nullptr, nullptr, nullptr};

    QGroupBox *eventsBox_ = nullptr;
    QComboBox *filterCombo_ = nullptr;
    QTableWidget *eventTable_ = nullptr;
    int newEventCount_ = 0;
    int highestKnownAbnormalBeat_ = -1;

    QGroupBox *reviewBox_ = nullptr;
    QLabel *selectedTitle_ = nullptr;
    QLabel *contextLabel_ = nullptr;
    QLabel *captureStatusLabel_ = nullptr;
    QComboBox *signalCombo_ = nullptr;
    QLabel *signalViewHint_ = nullptr;
    QPushButton *fitButton_ = nullptr;
    QPushButton *resetZoomButton_ = nullptr;
    QPushButton *focusButton_ = nullptr;
    QCustomPlot *plot_ = nullptr;
    QCPItemLine *rMarkers_[3] = {nullptr, nullptr, nullptr};
    QCPItemText *rLabels_[3] = {nullptr, nullptr, nullptr};

    QToolButton *aiDetailsButton_ = nullptr;
    QWidget *probabilityPanel_ = nullptr;
    QProgressBar *probabilityBars_[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    QPushButton *previousButton_ = nullptr;
    QPushButton *nextButton_ = nullptr;
    QPushButton *reviewedButton_ = nullptr;

    QLabel *noticeLabel_ = nullptr;
    QPushButton *closeButton_ = nullptr;

    bool focusMode_ = false;
    bool aiDetailsVisible_ = false;
    QRect normalGeometry_;
    double uiScale_ = 1.0;
};
