#include "abnormal_review_window.h"

#include "signal_buffer.h"

#include <QAbstractItemView>
#include <QBrush>
#include <QColor>
#include <QComboBox>
#include <QFont>
#include <QGridLayout>
#include <QGroupBox>
#include <QHeaderView>
#include <QHBoxLayout>
#include <QKeyEvent>
#include <QLabel>
#include <QProgressBar>
#include <QPushButton>
#include <QResizeEvent>
#include <QSignalBlocker>
#include <QStringList>
#include <QStyle>
#include <QTableWidget>
#include <QTableWidgetItem>
#include <QToolButton>
#include <QVBoxLayout>
#include <QWidget>

#include <algorithm>
#include <cmath>
#include <limits>

namespace
{
const QString kBg = "#030705";
const QString kPanel = "#07100C";
const QString kPanelRaised = "#0A1510";
const QString kTrace = "#32FF72";
const QString kMuted = "#789084";
const QString kText = "#EAF6EF";
const QString kWarning = "#FFD35E";
const QString kBorder = "#183022";

int px(const double value, const double scale)
{
    return std::max(1, static_cast<int>(std::lround(value * scale)));
}

QWidget *makeSummaryItem(const QString &caption, QLabel **valueOut, QWidget *parent)
{
    auto *item = new QWidget(parent);
    item->setObjectName("summaryItem");
    auto *layout = new QHBoxLayout(item);
    layout->setContentsMargins(10, 5, 10, 5);
    layout->setSpacing(7);

    auto *label = new QLabel(caption, item);
    label->setObjectName("summaryCaption");
    *valueOut = new QLabel("0", item);
    (*valueOut)->setObjectName("summaryValue");
    (*valueOut)->setAlignment(Qt::AlignRight | Qt::AlignVCenter);

    layout->addWidget(label);
    layout->addStretch(1);
    layout->addWidget(*valueOut);
    return item;
}
}

AbnormalReviewWindow::AbnormalReviewWindow(QWidget *parent)
    : QDialog(parent)
{
    setWindowTitle("Abnormal ECG Review");
    resize(1180, 760);
    setMinimumSize(980, 650);
    setModal(false);

    rootLayout_ = new QVBoxLayout(this);
    rootLayout_->setContentsMargins(14, 12, 14, 12);
    rootLayout_->setSpacing(8);

    // Header: keep only identity, monitoring state and window expansion.
    headerWidget_ = new QWidget(this);
    auto *header = new QHBoxLayout(headerWidget_);
    header->setContentsMargins(0, 0, 0, 0);
    header->setSpacing(8);

    titleLabel_ = new QLabel("ABNORMAL ECG REVIEW", headerWidget_);
    titleLabel_->setObjectName("reviewTitle");
    header->addWidget(titleLabel_);
    header->addStretch(1);

    liveStateLabel_ = new QLabel("● LIVE MONITORING", headerWidget_);
    liveStateLabel_->setObjectName("monitorState");
    liveStateLabel_->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
    header->addWidget(liveStateLabel_);

    expandButton_ = new QPushButton("Maximize", headerWidget_);
    expandButton_->setObjectName("secondaryButton");
    expandButton_->setToolTip("Maximize/restore this review window (F11)");
    header->addWidget(expandButton_);
    rootLayout_->addWidget(headerWidget_);

    // Compact summary strip replaces six large GroupBoxes.
    summaryStrip_ = new QWidget(this);
    summaryStrip_->setObjectName("summaryStrip");
    auto *summary = new QHBoxLayout(summaryStrip_);
    summary->setContentsMargins(0, 0, 0, 0);
    summary->setSpacing(6);
    summary->addWidget(makeSummaryItem("BEATS", &totalBeatsValue_, summaryStrip_));
    summary->addWidget(makeSummaryItem("ABNORMAL", &abnormalValue_, summaryStrip_));
    const QStringList statNames = {"S", "V", "F", "Q"};
    for (int i = 0; i < statNames.size(); ++i)
    {
        summary->addWidget(makeSummaryItem(statNames[i], &classValues_[i], summaryStrip_));
    }
    for (int i = 0; i < summary->count(); ++i) summary->setStretch(i, 1);
    rootLayout_->addWidget(summaryStrip_);

    auto *bodyWidget = new QWidget(this);
    bodyLayout_ = new QHBoxLayout(bodyWidget);
    bodyLayout_->setContentsMargins(0, 0, 0, 0);
    bodyLayout_->setSpacing(10);

    // Event list: confidence is intentionally moved to the detail pane.
    eventsBox_ = new QGroupBox("ABNORMAL EVENTS", bodyWidget);
    eventsBox_->setObjectName("eventsBox");
    auto *eventsLayout = new QVBoxLayout(eventsBox_);
    eventsLayout->setContentsMargins(10, 14, 10, 10);
    eventsLayout->setSpacing(7);

    auto *filterRow = new QHBoxLayout();
    auto *filterLabel = new QLabel("Filter", eventsBox_);
    filterLabel->setObjectName("mutedLabel");
    filterRow->addWidget(filterLabel);
    filterCombo_ = new QComboBox(eventsBox_);
    filterCombo_->addItem("All abnormal", -1);
    filterCombo_->addItem("Unreviewed", -2);
    filterCombo_->addItem("S — Supraventricular ectopic", 1);
    filterCombo_->addItem("V — Ventricular ectopic", 2);
    filterCombo_->addItem("F — Fusion", 3);
    filterCombo_->addItem("Q — Unknown / unclassifiable", 4);
    filterRow->addWidget(filterCombo_, 1);
    eventsLayout->addLayout(filterRow);

    eventTable_ = new QTableWidget(0, 4, eventsBox_);
    eventTable_->setHorizontalHeaderLabels({"Time", "Beat", "Type", "Status"});
    eventTable_->verticalHeader()->setVisible(false);
    eventTable_->setEditTriggers(QAbstractItemView::NoEditTriggers);
    eventTable_->setSelectionBehavior(QAbstractItemView::SelectRows);
    eventTable_->setSelectionMode(QAbstractItemView::SingleSelection);
    eventTable_->setAlternatingRowColors(true);
    eventTable_->setShowGrid(false);
    eventTable_->horizontalHeader()->setStretchLastSection(false);
    eventTable_->horizontalHeader()->setSectionResizeMode(0, QHeaderView::ResizeToContents);
    eventTable_->horizontalHeader()->setSectionResizeMode(1, QHeaderView::ResizeToContents);
    eventTable_->horizontalHeader()->setSectionResizeMode(2, QHeaderView::Stretch);
    eventTable_->horizontalHeader()->setSectionResizeMode(3, QHeaderView::ResizeToContents);
    eventsLayout->addWidget(eventTable_, 1);
    bodyLayout_->addWidget(eventsBox_, 0);

    reviewBox_ = new QGroupBox("SELECTED EVENT", bodyWidget);
    reviewBox_->setObjectName("reviewBox");
    auto *reviewLayout = new QVBoxLayout(reviewBox_);
    reviewLayout->setContentsMargins(12, 14, 12, 10);
    reviewLayout->setSpacing(6);

    selectedTitle_ = new QLabel("Select an abnormal event", reviewBox_);
    selectedTitle_->setObjectName("selectedTitle");
    contextLabel_ = new QLabel("", reviewBox_);
    contextLabel_->setObjectName("eventContext");
    captureStatusLabel_ = new QLabel("", reviewBox_);
    captureStatusLabel_->setObjectName("captureStatus");
    captureStatusLabel_->setWordWrap(true);
    captureStatusLabel_->setVisible(false);
    reviewLayout->addWidget(selectedTitle_);
    reviewLayout->addWidget(contextLabel_);
    reviewLayout->addWidget(captureStatusLabel_);

    // A single compact toolbar keeps view controls next to the waveform.
    auto *signalRow = new QHBoxLayout();
    signalRow->setSpacing(6);
    auto *signalLabel = new QLabel("Signal", reviewBox_);
    signalLabel->setObjectName("mutedLabel");
    signalRow->addWidget(signalLabel);
    signalCombo_ = new QComboBox(reviewBox_);
    signalCombo_->addItem("0.7–40 Hz · ST / T morphology", 10);
    signalCombo_->addItem("1–35 Hz · Rhythm / arrhythmia", 11);
    signalCombo_->addItem("5–25 Hz · Motion / tremor", 12);
    signalCombo_->addItem("Current processed display · 0.05–40 Hz", 0);
    signalCombo_->addItem("Raw monitor signal", 1);
    signalCombo_->setCurrentIndex(1);
    signalCombo_->setToolTip(
        "View preset only. Presets do not modify stored samples or the CNN input. Three-beat context remains unchanged.");
    signalRow->addWidget(signalCombo_, 1);

    fitButton_ = new QPushButton("Fit 3 beats", reviewBox_);
    fitButton_->setObjectName("secondaryButton");
    fitButton_->setToolTip("Fit the complete BEFORE → SELECTED → AFTER context");
    signalRow->addWidget(fitButton_);

    resetZoomButton_ = new QPushButton("Reset zoom", reviewBox_);
    resetZoomButton_->setObjectName("secondaryButton");
    resetZoomButton_->setToolTip("Restore the default ECG view after mouse zoom/pan");
    signalRow->addWidget(resetZoomButton_);

    focusButton_ = new QPushButton("ECG Focus", reviewBox_);
    focusButton_->setObjectName("secondaryButton");
    focusButton_->setToolTip("Hide secondary information and enlarge the ECG workspace (F)");
    signalRow->addWidget(focusButton_);
    reviewLayout->addLayout(signalRow);

    signalViewHint_ = new QLabel("", reviewBox_);
    signalViewHint_->setObjectName("signalHint");
    signalViewHint_->setVisible(false);
    signalViewHint_->setWordWrap(true);
    reviewLayout->addWidget(signalViewHint_);
    updateSignalHint();

    plot_ = new QCustomPlot(reviewBox_);
    plot_->setObjectName("reviewPlot");
    plot_->setMinimumHeight(340);
    plot_->setBackground(QBrush(QColor(kBg)));
    plot_->addGraph(); // complete three-beat context
    plot_->addGraph(); // selected/problem-beat emphasis
    plot_->axisRect()->setupFullAxesBox();
    plot_->xAxis->setLabel("Time within three-beat context (s)");
    plot_->yAxis->setLabel("Relative ECG amplitude");
    for (QCPAxis *axis : {plot_->xAxis, plot_->yAxis, plot_->xAxis2, plot_->yAxis2})
    {
        axis->setBasePen(QPen(QColor("#245636")));
        axis->setTickPen(QPen(QColor("#245636")));
        axis->setSubTickPen(QPen(QColor("#153D25")));
        axis->setTickLabelColor(QColor("#93A99B"));
        axis->setLabelColor(QColor("#93A99B"));
        axis->grid()->setPen(QPen(QColor("#153D25")));
        axis->grid()->setSubGridPen(QPen(QColor("#0A2416")));
        axis->grid()->setSubGridVisible(true);
    }
    plot_->setInteractions(QCP::iRangeDrag | QCP::iRangeZoom);

    const QString markerNames[3] = {"BEFORE", "SELECTED", "AFTER"};
    for (int i = 0; i < 3; ++i)
    {
        rMarkers_[i] = new QCPItemLine(plot_);
        rMarkers_[i]->setVisible(false);
        rLabels_[i] = new QCPItemText(plot_);
        rLabels_[i]->setText(markerNames[i]);
        rLabels_[i]->setPositionAlignment(Qt::AlignHCenter | Qt::AlignTop);
        rLabels_[i]->setVisible(false);
    }
    reviewLayout->addWidget(plot_, 1);

    // Secondary AI detail is collapsed by default so morphology remains primary.
    aiDetailsButton_ = new QToolButton(reviewBox_);
    aiDetailsButton_->setObjectName("aiDetailsButton");
    aiDetailsButton_->setText("AI DETAILS  ▸");
    aiDetailsButton_->setCheckable(true);
    aiDetailsButton_->setChecked(false);
    aiDetailsButton_->setToolButtonStyle(Qt::ToolButtonTextOnly);
    reviewLayout->addWidget(aiDetailsButton_);

    probabilityPanel_ = new QWidget(reviewBox_);
    probabilityPanel_->setObjectName("probabilityPanel");
    auto *probabilityLayout = new QGridLayout(probabilityPanel_);
    probabilityLayout->setContentsMargins(8, 6, 8, 6);
    probabilityLayout->setHorizontalSpacing(8);
    probabilityLayout->setVerticalSpacing(4);
    for (int classIndex = 0; classIndex < 5; ++classIndex)
    {
        auto *classLabel = new QLabel(QString("%1  %2")
                                          .arg(ecgClassShortName(classIndex), ecgClassLongName(classIndex)),
                                      probabilityPanel_);
        classLabel->setObjectName("probabilityLabel");
        probabilityBars_[classIndex] = new QProgressBar(probabilityPanel_);
        probabilityBars_[classIndex]->setRange(0, 1000);
        probabilityBars_[classIndex]->setValue(0);
        probabilityBars_[classIndex]->setFormat("0.0%");
        probabilityLayout->addWidget(classLabel, classIndex, 0);
        probabilityLayout->addWidget(probabilityBars_[classIndex], classIndex, 1);
    }
    probabilityLayout->setColumnStretch(1, 1);
    probabilityPanel_->setVisible(false);
    reviewLayout->addWidget(probabilityPanel_);

    auto *navigation = new QHBoxLayout();
    navigation->setSpacing(6);
    previousButton_ = new QPushButton("◀ Previous", reviewBox_);
    previousButton_->setObjectName("secondaryButton");
    nextButton_ = new QPushButton("Next ▶", reviewBox_);
    nextButton_->setObjectName("secondaryButton");
    reviewedButton_ = new QPushButton("Mark reviewed", reviewBox_);
    reviewedButton_->setObjectName("primaryButton");
    navigation->addWidget(previousButton_);
    navigation->addWidget(nextButton_);
    navigation->addStretch(1);
    navigation->addWidget(reviewedButton_);
    reviewLayout->addLayout(navigation);

    bodyLayout_->addWidget(reviewBox_, 1);
    rootLayout_->addWidget(bodyWidget, 1);

    auto *footer = new QHBoxLayout();
    noticeLabel_ = new QLabel("ⓘ Research/demo only — not for clinical diagnosis.", this);
    noticeLabel_->setObjectName("footerNote");
    noticeLabel_->setToolTip(
        "Research/demo AI output. Review status is a workflow aid and does not represent a clinical diagnosis.");
    footer->addWidget(noticeLabel_);
    footer->addStretch(1);
    closeButton_ = new QPushButton("Close", this);
    closeButton_->setObjectName("secondaryButton");
    footer->addWidget(closeButton_);
    rootLayout_->addLayout(footer);

    connect(closeButton_, &QPushButton::clicked, this, [this]() { hide(); });
    connect(expandButton_, &QPushButton::clicked, this, &AbnormalReviewWindow::toggleExpandedMode);
    connect(focusButton_, &QPushButton::clicked, this, &AbnormalReviewWindow::toggleFocusMode);
    connect(fitButton_, &QPushButton::clicked, this, &AbnormalReviewWindow::fitPlotToSelectedEvent);
    connect(resetZoomButton_, &QPushButton::clicked, this, &AbnormalReviewWindow::fitPlotToSelectedEvent);
    connect(aiDetailsButton_, &QToolButton::toggled, this, &AbnormalReviewWindow::setAiDetailsVisible);

    connect(filterCombo_, QOverload<int>::of(&QComboBox::currentIndexChanged), this, [this](int) {
        rebuildTable();
    });
    connect(eventTable_, &QTableWidget::currentCellChanged, this,
            [this](int, int, int, int) { updateSelectedRecord(); });
    connect(signalCombo_, QOverload<int>::of(&QComboBox::currentIndexChanged), this,
            [this](int) {
                updateSignalHint();
                updateSelectedRecord();
            });
    connect(previousButton_, &QPushButton::clicked, this, [this]() {
        const int row = eventTable_->currentRow();
        if (row > 0) eventTable_->selectRow(row - 1);
    });
    connect(nextButton_, &QPushButton::clicked, this, [this]() {
        const int row = eventTable_->currentRow();
        if (row >= 0 && row + 1 < eventTable_->rowCount()) eventTable_->selectRow(row + 1);
    });
    connect(reviewedButton_, &QPushButton::clicked, this, [this]() {
        const int historyIndex = selectedHistoryIndex();
        if (historyIndex < 0 || historyIndex >= history_.size()) return;
        HistoryRecord &record = history_[historyIndex];
        record.reviewed = !record.reviewed;
        const int beatIndex = record.result.beatIndex;
        const bool reviewed = record.reviewed;
        emit reviewStateChanged(beatIndex, reviewed);
        rebuildTable();
        selectBeat(beatIndex);
    });

    applyResponsiveScale(true);
    updateSummaryCards();
    updateSelectedRecord();
}

void AbnormalReviewWindow::resizeEvent(QResizeEvent *event)
{
    QDialog::resizeEvent(event);
    applyResponsiveScale();
}

void AbnormalReviewWindow::keyPressEvent(QKeyEvent *event)
{
    if (event->key() == Qt::Key_F11)
    {
        toggleExpandedMode();
        event->accept();
        return;
    }
    if (event->key() == Qt::Key_F && !(event->modifiers() & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier)))
    {
        toggleFocusMode();
        event->accept();
        return;
    }
    if (event->key() == Qt::Key_Escape)
    {
        if (focusMode_)
        {
            setFocusMode(false);
            event->accept();
            return;
        }
        if (isMaximized())
        {
            toggleExpandedMode();
            event->accept();
            return;
        }
    }
    QDialog::keyPressEvent(event);
}

void AbnormalReviewWindow::setData(const QVector<HistoryRecord> &history,
                                   const QVector<int> &eventCounts,
                                   const bool monitoringLive)
{
    int selectedBeat = -1;
    HistoryRecord oldSelectedRecord;
    bool hadSelectedRecord = false;
    const int selected = selectedHistoryIndex();
    if (selected >= 0 && selected < history_.size())
    {
        selectedBeat = history_[selected].result.beatIndex;
        oldSelectedRecord = history_[selected];
        hadSelectedRecord = true;
    }

    int incomingHighestAbnormalBeat = highestKnownAbnormalBeat_;
    int newlyArrived = 0;
    for (const HistoryRecord &record : history)
    {
        if (!record.result.valid || record.result.classIndex <= 0) continue;
        incomingHighestAbnormalBeat = std::max(incomingHighestAbnormalBeat, record.result.beatIndex);
        if (isVisible() && record.result.beatIndex > highestKnownAbnormalBeat_) ++newlyArrived;
    }
    if (!isVisible()) newEventCount_ = 0;
    else newEventCount_ += newlyArrived;
    highestKnownAbnormalBeat_ = incomingHighestAbnormalBeat;

    history_ = history;
    eventCounts_ = eventCounts;
    while (eventCounts_.size() < 5) eventCounts_.append(0);

    liveStateLabel_->setText(monitoringLive ? "● LIVE MONITORING" : "● MONITOR PAUSED");
    liveStateLabel_->setProperty("paused", !monitoringLive);
    liveStateLabel_->style()->unpolish(liveStateLabel_);
    liveStateLabel_->style()->polish(liveStateLabel_);

    bool selectedRecordUnchanged = false;
    if (hadSelectedRecord && selectedBeat >= 0)
    {
        for (const HistoryRecord &record : history_)
        {
            if (record.result.beatIndex != selectedBeat) continue;
            selectedRecordUnchanged =
                record.contextReady == oldSelectedRecord.contextReady &&
                record.reviewed == oldSelectedRecord.reviewed &&
                record.rawSignal.size() == oldSelectedRecord.rawSignal.size() &&
                record.processedSignal.size() == oldSelectedRecord.processedSignal.size() &&
                record.result.classIndex == oldSelectedRecord.result.classIndex &&
                std::abs(record.result.confidence - oldSelectedRecord.result.confidence) < 1e-6f;
            break;
        }
    }

    updateSummaryCards();
    updateNewEventBadge();
    rebuildTable(!selectedRecordUnchanged);
    if (selectedBeat >= 0 && !selectedRecordUnchanged) selectBeat(selectedBeat);
}

void AbnormalReviewWindow::selectBeat(const int beatIndex)
{
    for (int row = 0; row < filteredHistoryIndices_.size(); ++row)
    {
        const int historyIndex = filteredHistoryIndices_[row];
        if (historyIndex >= 0 && historyIndex < history_.size() &&
            history_[historyIndex].result.beatIndex == beatIndex)
        {
            eventTable_->selectRow(row);
            eventTable_->scrollToItem(eventTable_->item(row, 0), QAbstractItemView::PositionAtCenter);
            return;
        }
    }
}

void AbnormalReviewWindow::updateSummaryCards()
{
    int total = 0;
    for (int count : eventCounts_) total += count;

    QVector<int> reportedCounts(5, 0);
    for (const HistoryRecord &record : history_)
    {
        if (record.result.valid && record.result.classIndex >= 0 && record.result.classIndex < reportedCounts.size())
        {
            ++reportedCounts[record.result.classIndex];
        }
    }

    int abnormal = 0;
    for (int classIndex = 1; classIndex < reportedCounts.size(); ++classIndex) abnormal += reportedCounts[classIndex];

    totalBeatsValue_->setText(QString::number(total));
    abnormalValue_->setText(QString::number(abnormal));
    for (int i = 0; i < 4; ++i)
    {
        classValues_[i]->setText(QString::number(reportedCounts.value(i + 1, 0)));
        classValues_[i]->setStyleSheet(QString("color:%1;font-weight:700;").arg(classColor(i + 1)));
    }
}

void AbnormalReviewWindow::rebuildTable(const bool refreshSelected)
{
    int selectedBeat = -1;
    const int oldHistoryIndex = selectedHistoryIndex();
    if (oldHistoryIndex >= 0 && oldHistoryIndex < history_.size()) selectedBeat = history_[oldHistoryIndex].result.beatIndex;

    const int filter = filterCombo_->currentData().toInt();
    filteredHistoryIndices_.clear();
    for (int index = 0; index < history_.size(); ++index)
    {
        const HistoryRecord &record = history_[index];
        if (!record.result.valid || record.result.classIndex <= 0 || record.result.classIndex > 4) continue;
        if (filter == -2 && record.reviewed) continue;
        if (filter >= 1 && filter <= 4 && record.result.classIndex != filter) continue;
        filteredHistoryIndices_.append(index);
    }

    QSignalBlocker blocker(eventTable_);
    eventTable_->setRowCount(filteredHistoryIndices_.size());
    for (int row = 0; row < filteredHistoryIndices_.size(); ++row)
    {
        const HistoryRecord &record = history_[filteredHistoryIndices_[row]];
        const QString status = record.reviewed ? "✓" : (record.contextReady ? "●" : "…");
        const QStringList cells = {
            formatSessionTime(record.result.timeSeconds),
            QString::number(record.result.beatIndex),
            ecgClassShortName(record.result.classIndex),
            status};

        for (int col = 0; col < cells.size(); ++col)
        {
            auto *item = new QTableWidgetItem(cells[col]);
            item->setTextAlignment(Qt::AlignCenter);
            if (col == 2) item->setForeground(QBrush(QColor(classColor(record.result.classIndex))));
            if (col == 3)
            {
                item->setToolTip(record.reviewed ? "Reviewed" : (record.contextReady ? "Unreviewed" : "Collecting context"));
                item->setForeground(QBrush(QColor(record.reviewed ? kTrace : (record.contextReady ? kWarning : kMuted))));
            }
            eventTable_->setItem(row, col, item);
        }
    }

    if (eventTable_->rowCount() == 0)
    {
        eventTable_->clearSelection();
        eventTable_->setCurrentItem(nullptr);
        updateSelectedRecord();
        return;
    }

    int targetRow = 0;
    if (selectedBeat >= 0)
    {
        for (int row = 0; row < filteredHistoryIndices_.size(); ++row)
        {
            if (history_[filteredHistoryIndices_[row]].result.beatIndex == selectedBeat)
            {
                targetRow = row;
                break;
            }
        }
    }
    else
    {
        for (int row = 0; row < filteredHistoryIndices_.size(); ++row)
        {
            if (!history_[filteredHistoryIndices_[row]].reviewed)
            {
                targetRow = row;
                break;
            }
        }
    }

    eventTable_->setCurrentCell(targetRow, 0);
    eventTable_->selectRow(targetRow);
    if (refreshSelected)
    {
        updateSelectedRecord();
    }
    else
    {
        previousButton_->setEnabled(targetRow > 0);
        nextButton_->setEnabled(targetRow + 1 < eventTable_->rowCount());
    }
}

int AbnormalReviewWindow::selectedHistoryIndex() const
{
    const int row = eventTable_->currentRow();
    if (row < 0 || row >= filteredHistoryIndices_.size()) return -1;
    return filteredHistoryIndices_[row];
}

void AbnormalReviewWindow::updateSelectedRecord()
{
    const int historyIndex = selectedHistoryIndex();
    if (historyIndex < 0 || historyIndex >= history_.size())
    {
        selectedTitle_->setText("No abnormal event selected");
        contextLabel_->setText("No non-N event matches the current filter.");
        captureStatusLabel_->setVisible(false);
        previousButton_->setEnabled(false);
        nextButton_->setEnabled(false);
        reviewedButton_->setEnabled(false);
        fitButton_->setEnabled(false);
        resetZoomButton_->setEnabled(false);
        updatePlot(nullptr);
        updateProbabilities(nullptr);
        return;
    }

    const HistoryRecord &record = history_[historyIndex];
    selectedTitle_->setText(QString("Beat %1  ·  %2  ·  %3%")
                                .arg(record.result.beatIndex)
                                .arg(record.result.displayLabel)
                                .arg(record.result.confidence * 100.0f, 0, 'f', 1));

    if (record.contextReady)
    {
        // Compact replacement for the old verbose Three-beat context note.
        contextLabel_->setText(QString("%1    %2  →  %3  →  %4")
                                   .arg(formatSessionTime(record.result.timeSeconds))
                                   .arg(ecgClassShortName(record.previousClassIndex))
                                   .arg(ecgClassShortName(record.problemClassIndex))
                                   .arg(ecgClassShortName(record.nextClassIndex)));
        captureStatusLabel_->setVisible(false);
    }
    else
    {
        contextLabel_->setText(QString("%1    Reported: %2")
                                   .arg(formatSessionTime(record.result.timeSeconds))
                                   .arg(ecgClassLongName(record.result.classIndex)));
        captureStatusLabel_->setText("Collecting the following beat to complete review context…");
        captureStatusLabel_->setVisible(true);
    }

    previousButton_->setEnabled(eventTable_->currentRow() > 0);
    nextButton_->setEnabled(eventTable_->currentRow() + 1 < eventTable_->rowCount());
    reviewedButton_->setEnabled(record.contextReady);
    reviewedButton_->setText(record.reviewed ? "Mark unreviewed" : "Mark reviewed");
    fitButton_->setEnabled(record.contextReady);
    resetZoomButton_->setEnabled(record.contextReady);

    updatePlot(&record);
    updateProbabilities(&record);
}

void AbnormalReviewWindow::updatePlot(const HistoryRecord *record)
{
    plot_->graph(0)->data()->clear();
    plot_->graph(1)->data()->clear();
    for (int i = 0; i < 3; ++i)
    {
        rMarkers_[i]->setVisible(false);
        rLabels_[i]->setVisible(false);
    }

    if (record == nullptr || !record->contextReady)
    {
        plot_->xAxis->setRange(0.0, 3.0);
        plot_->yAxis->setRange(-1.6, 1.6);
        refreshPlotScale();
        plot_->replot(QCustomPlot::rpQueuedReplot);
        return;
    }

    const bool raw = signalCombo_->currentData().toInt() == 1;
    const QVector<double> &signal = raw ? record->rawSignal : record->processedSignal;
    if (signal.isEmpty())
    {
        plot_->replot(QCustomPlot::rpQueuedReplot);
        return;
    }

    QVector<double> keys;
    keys.reserve(signal.size());
    for (int i = 0; i < signal.size(); ++i) keys.append(static_cast<double>(i) / SignalBuffer::kSampleRate);
    plot_->graph(0)->setData(keys, signal, true);

    QVector<double> problemSignal(signal.size(), std::numeric_limits<double>::quiet_NaN());
    const int leftBoundary = std::max(0, (record->previousRIndex + record->problemRIndex) / 2);
    const int rightBoundary = std::min(signal.size(), (record->problemRIndex + record->nextRIndex) / 2 + 1);
    for (int i = leftBoundary; i < rightBoundary; ++i) problemSignal[i] = signal[i];
    plot_->graph(1)->setData(keys, problemSignal, true);

    double minValue = std::numeric_limits<double>::infinity();
    double maxValue = -std::numeric_limits<double>::infinity();
    for (const double value : signal)
    {
        if (!std::isfinite(value)) continue;
        minValue = std::min(minValue, value);
        maxValue = std::max(maxValue, value);
    }
    if (!std::isfinite(minValue) || !std::isfinite(maxValue) || maxValue <= minValue)
    {
        minValue = -1.0;
        maxValue = 1.0;
    }
    const double amplitude = std::max(0.4, maxValue - minValue);
    const double margin = 0.18 * amplitude;
    const double yMin = minValue - margin;
    const double yMax = maxValue + margin;

    const int markerIndices[3] = {record->previousRIndex, record->problemRIndex, record->nextRIndex};
    const QString markerPrefix[3] = {"BEFORE", "SELECTED", "AFTER"};
    for (int i = 0; i < 3; ++i)
    {
        if (markerIndices[i] < 0 || markerIndices[i] >= signal.size()) continue;
        const double x = static_cast<double>(markerIndices[i]) / SignalBuffer::kSampleRate;
        const QColor color(i == 1 ? classColor(record->result.classIndex) : kMuted);
        QPen pen(color, i == 1 ? px(2.0, uiScale_) : px(1.0, uiScale_),
                 i == 1 ? Qt::SolidLine : Qt::DashLine);
        rMarkers_[i]->setPen(pen);
        rMarkers_[i]->start->setCoords(x, yMin);
        rMarkers_[i]->end->setCoords(x, yMax);
        rMarkers_[i]->setVisible(true);

        rLabels_[i]->setText(markerPrefix[i]);
        rLabels_[i]->setColor(color);
        rLabels_[i]->position->setCoords(x, yMax - 0.04 * (yMax - yMin));
        rLabels_[i]->setVisible(true);
    }

    plot_->xAxis->setRange(0.0, static_cast<double>(std::max(1, signal.size() - 1)) / SignalBuffer::kSampleRate);
    plot_->yAxis->setRange(yMin, yMax);
    refreshPlotScale();
    plot_->replot(QCustomPlot::rpQueuedReplot);
}

void AbnormalReviewWindow::updateProbabilities(const HistoryRecord *record)
{
    for (int classIndex = 0; classIndex < 5; ++classIndex)
    {
        const float probability = record != nullptr
                                      ? std::clamp(record->result.probabilities.value(classIndex, 0.0f), 0.0f, 1.0f)
                                      : 0.0f;
        probabilityBars_[classIndex]->setValue(static_cast<int>(std::lround(probability * 1000.0f)));
        probabilityBars_[classIndex]->setFormat(QString("%1%").arg(probability * 100.0f, 0, 'f', 1));
    }
}

void AbnormalReviewWindow::updateNewEventBadge()
{
    if (eventsBox_ == nullptr) return;
    eventsBox_->setTitle(newEventCount_ > 0
                             ? QString("ABNORMAL EVENTS    +%1 NEW").arg(newEventCount_)
                             : QString("ABNORMAL EVENTS"));
}

void AbnormalReviewWindow::updateSignalHint()
{
    const int mode = signalCombo_->currentData().toInt();
    switch (mode)
    {
    case 10:
        signalViewHint_->setText("0.7–40 Hz view preset · ST deviation, R amplitude, T-wave morphology");
        break;
    case 12:
        signalViewHint_->setText("5–25 Hz view preset · rate/rhythm under motion or tremor");
        break;
    case 0:
        signalViewHint_->setText("Current processed display · existing 0.05–40 Hz display-only processing");
        break;
    case 1:
        signalViewHint_->setText("Raw monitor signal · no additional review-view processing");
        break;
    case 11:
    default:
        signalViewHint_->setText("1–35 Hz view preset · P waves, RR intervals, ectopic rhythm");
        break;
    }
    signalCombo_->setToolTip(signalViewHint_->text() +
                             "\nView preset only; stored samples and CNN input are unchanged.");
}

void AbnormalReviewWindow::fitPlotToSelectedEvent()
{
    const int historyIndex = selectedHistoryIndex();
    if (historyIndex < 0 || historyIndex >= history_.size()) return;
    updatePlot(&history_[historyIndex]);
}

void AbnormalReviewWindow::toggleExpandedMode()
{
    if (isMaximized())
    {
        showNormal();
        if (normalGeometry_.isValid()) setGeometry(normalGeometry_);
        expandButton_->setText("Maximize");
    }
    else
    {
        normalGeometry_ = geometry();
        showMaximized();
        expandButton_->setText("Restore");
    }
    applyResponsiveScale(true);
}

void AbnormalReviewWindow::toggleFocusMode()
{
    setFocusMode(!focusMode_);
}

void AbnormalReviewWindow::setFocusMode(const bool enabled)
{
    focusMode_ = enabled;
    eventsBox_->setVisible(!enabled);
    summaryStrip_->setVisible(!enabled);
    noticeLabel_->setVisible(!enabled);
    closeButton_->setVisible(!enabled);
    aiDetailsButton_->setVisible(!enabled);
    probabilityPanel_->setVisible(!enabled && aiDetailsVisible_);
    focusButton_->setText(enabled ? "Exit Focus" : "ECG Focus");
    reviewBox_->setTitle(enabled ? "ECG FOCUS" : "SELECTED EVENT");
    plot_->setMinimumHeight(enabled ? px(500, uiScale_) : px(340, uiScale_));
    applyResponsiveScale(true);
}

void AbnormalReviewWindow::setAiDetailsVisible(const bool visible)
{
    aiDetailsVisible_ = visible;
    aiDetailsButton_->setText(visible ? "AI DETAILS  ▾" : "AI DETAILS  ▸");
    probabilityPanel_->setVisible(visible && !focusMode_);
}

void AbnormalReviewWindow::applyResponsiveScale(const bool force)
{
    if (width() <= 0 || height() <= 0) return;
    const double widthScale = static_cast<double>(width()) / 1180.0;
    const double heightScale = static_cast<double>(height()) / 760.0;
    const double newScale = std::clamp(std::min(widthScale, heightScale), 1.0, 1.40);
    if (!force && std::abs(newScale - uiScale_) < 0.035) return;
    uiScale_ = newScale;

    rootLayout_->setContentsMargins(px(14, uiScale_), px(12, uiScale_), px(14, uiScale_), px(12, uiScale_));
    rootLayout_->setSpacing(px(8, uiScale_));
    bodyLayout_->setSpacing(px(10, uiScale_));

    eventsBox_->setMinimumWidth(px(285, uiScale_));
    eventsBox_->setMaximumWidth(px(355, uiScale_));
    eventTable_->verticalHeader()->setDefaultSectionSize(px(28, uiScale_));
    eventTable_->horizontalHeader()->setMinimumHeight(px(28, uiScale_));

    plot_->setMinimumHeight(focusMode_ ? px(500, uiScale_) : px(340, uiScale_));
    refreshStyleSheet();
    refreshPlotScale();
    plot_->replot(QCustomPlot::rpQueuedReplot);
}

void AbnormalReviewWindow::refreshStyleSheet()
{
    const int baseFont = px(12, uiScale_);
    const int smallFont = px(10, uiScale_);
    const int mutedFont = px(11, uiScale_);
    const int titleFont = px(20, uiScale_);
    const int selectedFont = px(15, uiScale_);
    const int summaryFont = px(17, uiScale_);
    const int radius = px(6, uiScale_);
    const int buttonPadV = px(6, uiScale_);
    const int buttonPadH = px(9, uiScale_);
    const int headerPad = px(6, uiScale_);
    const int progressHeight = px(18, uiScale_);

    setStyleSheet(QString(
        "QDialog,QWidget{background:%1;color:%2;font-size:%3px;}"
        "QGroupBox{background:%4;border:1px solid %5;border-radius:%6px;margin-top:%7px;padding-top:%8px;font-weight:600;}"
        "QGroupBox::title{subcontrol-origin:margin;left:%9px;padding:0 %10px;color:#A7B8AD;font-size:%11px;}"
        "QPushButton,QComboBox,QToolButton{background:#122019;color:%2;border:1px solid #254433;border-radius:%6px;padding:%12px %13px;}"
        "QPushButton:hover,QToolButton:hover{background:#173B25;border-color:%14;}"
        "QPushButton:disabled{color:#506058;background:#0A120E;border-color:#14261B;}"
        "QPushButton#primaryButton{background:#183A28;border-color:#2C6844;font-weight:700;}"
        "QPushButton#primaryButton:hover{background:#225332;border-color:%14;}"
        "QTableWidget{background:#050B08;alternate-background-color:#08110C;color:%2;border:0;gridline-color:transparent;}"
        "QTableWidget::item{padding:%15px;}"
        "QTableWidget::item:selected{background:#164A29;color:#EAF6EF;}"
        "QHeaderView::section{background:#0B1710;color:#A7B8AD;padding:%16px;border:0;font-size:%11px;}"
        "QProgressBar{border:1px solid #254433;border-radius:%17px;background:#050B08;text-align:center;height:%18px;font-size:%11px;}"
        "QProgressBar::chunk{background:#1E7A3D;border-radius:%17px;}"
        "QLabel{background:transparent;}"
        "QLabel#reviewTitle{font-size:%19px;font-weight:700;color:%14;}"
        "QLabel#monitorState{font-weight:700;color:%14;}"
        "QLabel#monitorState[paused=\"true\"]{color:%20;}"
        "QWidget#summaryItem{background:%4;border:1px solid %5;border-radius:%6px;}"
        "QLabel#summaryCaption{color:#8EA095;font-size:%11px;font-weight:600;}"
        "QLabel#summaryValue{color:%2;font-size:%21px;font-weight:700;}"
        "QLabel#selectedTitle{font-size:%22px;font-weight:700;}"
        "QLabel#eventContext{color:#A5B8AC;font-size:%23px;}"
        "QLabel#captureStatus,QLabel#signalHint,QLabel#footerNote{color:%24;font-size:%11px;}"
        "QLabel#mutedLabel,QLabel#probabilityLabel{color:#A5B8AC;font-size:%23px;}"
        "QToolButton#aiDetailsButton{text-align:left;background:%25;border:1px solid %5;}"
        "QWidget#probabilityPanel{background:%25;border:1px solid %5;border-radius:%6px;}"
    )
        .arg(kBg)                        // 1
        .arg(kText)                      // 2
        .arg(baseFont)                   // 3
        .arg(kPanel)                     // 4
        .arg(kBorder)                    // 5
        .arg(radius)                     // 6
        .arg(px(9, uiScale_))            // 7
        .arg(px(9, uiScale_))            // 8
        .arg(px(10, uiScale_))           // 9
        .arg(px(5, uiScale_))            // 10
        .arg(smallFont)                  // 11
        .arg(buttonPadV)                 // 12
        .arg(buttonPadH)                 // 13
        .arg(kTrace)                     // 14
        .arg(px(4, uiScale_))            // 15
        .arg(headerPad)                  // 16
        .arg(px(4, uiScale_))            // 17
        .arg(progressHeight)             // 18
        .arg(titleFont)                  // 19
        .arg(kWarning)                   // 20
        .arg(summaryFont)                // 21
        .arg(selectedFont)               // 22
        .arg(mutedFont)                  // 23
        .arg(kMuted)                     // 24
        .arg(kPanelRaised));             // 25
}

void AbnormalReviewWindow::refreshPlotScale()
{
    if (plot_ == nullptr) return;

    QFont tickFont = font();
    tickFont.setPixelSize(px(10, uiScale_));
    QFont labelFont = font();
    labelFont.setPixelSize(px(11, uiScale_));
    for (QCPAxis *axis : {plot_->xAxis, plot_->yAxis, plot_->xAxis2, plot_->yAxis2})
    {
        axis->setTickLabelFont(tickFont);
        axis->setLabelFont(labelFont);
    }

    QFont markerFont = font();
    markerFont.setPixelSize(px(9, uiScale_));
    markerFont.setBold(true);
    for (int i = 0; i < 3; ++i) rLabels_[i]->setFont(markerFont);

    plot_->graph(0)->setPen(QPen(QColor(kTrace), px(2.0, uiScale_)));
    const int historyIndex = selectedHistoryIndex();
    const QString selectedColor = (historyIndex >= 0 && historyIndex < history_.size())
                                      ? classColor(history_[historyIndex].result.classIndex)
                                      : QString("#FF6670");
    plot_->graph(1)->setPen(QPen(QColor(selectedColor), px(3.0, uiScale_)));
}

QString AbnormalReviewWindow::formatSessionTime(const double seconds) const
{
    const double safeSeconds = std::max(0.0, seconds);
    const qint64 centiseconds = static_cast<qint64>(std::llround(safeSeconds * 100.0));
    const qint64 minutes = centiseconds / 6000;
    const qint64 secondsPart = (centiseconds / 100) % 60;
    const qint64 hundredths = centiseconds % 100;
    return QString("%1:%2.%3")
        .arg(minutes, 2, 10, QChar('0'))
        .arg(secondsPart, 2, 10, QChar('0'))
        .arg(hundredths, 2, 10, QChar('0'));
}

QString AbnormalReviewWindow::classColor(const int classIndex) const
{
    switch (classIndex)
    {
    case 0: return kTrace;
    case 1: return "#8D7CFF";
    case 2: return "#FF6670";
    case 3: return "#FFD35E";
    case 4: return "#B7C2BA";
    default: return kText;
    }
}
