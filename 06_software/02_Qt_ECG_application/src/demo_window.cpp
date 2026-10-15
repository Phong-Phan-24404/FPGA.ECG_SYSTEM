#include "demo_window.h"

#include "abnormal_review_window.h"
#include "signal_buffer.h"

#include <QAbstractButton>
#include <QButtonGroup>
#include <QDateTime>
#include <QDialog>
#include <QDialogButtonBox>
#include <QComboBox>
#include <QFrame>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QGroupBox>
#include <QHeaderView>
#include <QLabel>
#include <QMessageBox>
#include <QPushButton>
#include <QSlider>
#include <QSpinBox>
#include <QStyle>
#include <QTableWidget>
#include <QTableWidgetItem>
#include <QTimer>
#include <QVBoxLayout>
#include <QWidget>
#include <QtGlobal>

#include <algorithm>
#include <cmath>
#include <limits>

namespace
{
const QString kBg = "#030705";
const QString kPanel = "#07100C";
const QString kPanel2 = "#09140F";
const QString kTrace = "#32FF72";
const QString kMuted = "#789084";
const QString kText = "#EAF6EF";
const QString kWarning = "#FFD35E";
constexpr double kPlotWindowSeconds = 9.0; // 10% zoom from the original 10 s view
constexpr int kHistoryVisibleRows = 8;
constexpr int kHistoryRowHeight = 24;
}

DemoWindow::DemoWindow(QWidget *parent)
    : QMainWindow(parent)
{
    setWindowTitle("Realtime ECG Classification");
    resize(1480, 900);
    setMinimumSize(1200, 780);
    setStyleSheet(QString(
        "QMainWindow,QWidget{background:%1;color:%2;}"
        "QGroupBox{border:1px solid #183022;border-radius:7px;margin-top:10px;padding-top:10px;font-weight:600;}"
        "QGroupBox::title{subcontrol-origin:margin;left:10px;padding:0 5px;color:#A7B8AD;}"
        "QPushButton,QSlider{background:#122019;color:%2;border:1px solid #254433;border-radius:5px;padding:6px;}"
        "QPushButton{min-height:24px;font-weight:600;}"
        "QPushButton:hover{background:#225332;border-color:#32FF72;}"
        "QPushButton:pressed{background:#183D26;}"
        "QPushButton[hasEvents=\"true\"]{border:1px solid #FF6670;color:#FFD8DB;}"
        // Bao dong duoc to nen do dac chu khong chi doi vien: o day no phai
        // doc duoc tu xa, luc nguoi dung khong nhin thang vao man hinh.
        "QPushButton[alarm=\"true\"]{background:#7A121B;border:1px solid #FF4D5A;color:#FFE3E6;}"
        "QPushButton[alarm=\"true\"]:hover{background:#96161F;border-color:#FF6670;}"
        "QPushButton[rhythmSelector=\"true\"]{min-width:34px;min-height:28px;padding:2px 0;font-size:13px;font-weight:700;color:#A7B8AD;}"
        "QPushButton[rhythmSelector=\"true\"]:checked{background:#164A29;border:1px solid #32FF72;color:#32FF72;}"
        "QPushButton[backendSelector=\"true\"]{min-width:54px;min-height:24px;padding:2px 10px;font-size:11px;font-weight:700;color:#A7B8AD;}"
        "QPushButton[backendSelector=\"true\"]:checked{background:#164A29;border:1px solid #32FF72;color:#32FF72;}"
        "QPushButton[backendSelector=\"true\"]:disabled{color:#506158;background:#0A100D;border-color:#17261D;}"
        "QComboBox{background:#0B1710;color:%2;border:1px solid #254433;border-radius:5px;padding:5px 8px;min-height:24px;}"
        "QComboBox:hover{border-color:#32FF72;}"
        "QComboBox QAbstractItemView{background:#08110C;color:%2;selection-background-color:#164A29;border:1px solid #254433;}"
        "QTableWidget{background:#050B08;alternate-background-color:#08110C;color:%2;gridline-color:#173523;border:1px solid #183022;border-radius:5px;}"
        "QHeaderView::section{background:#0B1710;color:#A7B8AD;padding:5px;border:0;}"
        "QLabel{background:transparent;}"
    ).arg(kBg, kText));

    auto *central = new QWidget(this);
    auto *root = new QVBoxLayout(central);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    // Keep the product header deliberately compact. Technical implementation
    // details belong in tooltips/status, not in the primary visual hierarchy.
    auto *header = new QFrame(central);
    header->setStyleSheet(QString("background:%1;").arg(kPanel2));
    auto *headerLayout = new QGridLayout(header);
    headerLayout->setContentsMargins(18, 10, 18, 10);
    auto *title = new QLabel("REALTIME ECG CLASSIFICATION", header);
    title->setStyleSheet("font-size:20px;font-weight:700;letter-spacing:0.5px;");
    liveLabel_ = new QLabel("● LIVE", header);
    liveLabel_->setStyleSheet(QString("color:%1;font-size:14px;font-weight:700;").arg(kTrace));
    clockLabel_ = new QLabel("--:--:--", header);
    clockLabel_->setStyleSheet("font-family:monospace;font-size:17px;font-weight:700;");
    headerLayout->addWidget(title, 0, 0);
    headerLayout->setColumnStretch(0, 1);
    headerLayout->addWidget(liveLabel_, 0, 1, Qt::AlignVCenter | Qt::AlignRight);
    headerLayout->addWidget(clockLabel_, 0, 2, Qt::AlignVCenter | Qt::AlignRight);
    root->addWidget(header);

    auto *main = new QWidget(central);
    auto *mainLayout = new QGridLayout(main);
    mainLayout->setContentsMargins(12, 12, 12, 12);
    mainLayout->setHorizontalSpacing(10);
    mainLayout->setVerticalSpacing(8);

    auto *left = new QFrame(main);
    left->setStyleSheet(QString("background:%1;border-radius:7px;").arg(kPanel));
    auto *leftLayout = new QVBoxLayout(left);
    leftLayout->setContentsMargins(12, 10, 12, 10);
    leftLayout->setSpacing(8);

    auto *leadBar = new QGridLayout();
    auto *leadLabel = new QLabel("ECG LEAD II", left);
    leadLabel->setStyleSheet(QString("color:%1;font-size:14px;font-weight:700;").arg(kTrace));
    leadBar->addWidget(leadLabel, 0, 0);
    leadBar->setColumnStretch(1, 1);

    displayFilterCombo_ = new QComboBox(left);
    displayFilterCombo_->addItem("0.7–40 Hz · Morphology", 0);
    displayFilterCombo_->addItem("1–35 Hz · Rhythm", 1);
    displayFilterCombo_->addItem("5–25 Hz · Motion", 2);
    displayFilterCombo_->setCurrentIndex(1);
    displayFilterCombo_->setToolTip(
        "Display preset only. The source sample and classifier input are unchanged.");
    leadBar->addWidget(displayFilterCombo_, 0, 2);
    leftLayout->addLayout(leadBar);

    plot_ = new QCustomPlot(left);
    plot_->setMinimumHeight(400);
    leftLayout->addWidget(plot_, 1);
    configurePlot();

    // Hidden during normal operation; only actionable status/errors are shown.
    statusLabel_ = new QLabel(left);
    statusLabel_->setWordWrap(true);
    statusLabel_->setStyleSheet(QString("color:%1;font-size:10px;").arg(kMuted));
    statusLabel_->hide();
    leftLayout->addWidget(statusLabel_);

    auto *bottom = new QFrame(main);
    bottom->setStyleSheet(QString("background:%1;border-radius:7px;").arg(kPanel));

    auto *right = new QFrame(main);
    right->setFixedWidth(450);
    right->setStyleSheet(QString("background:%1;border-radius:7px;").arg(kPanel));
    auto *rightLayout = new QVBoxLayout(right);
    rightLayout->setContentsMargins(14, 12, 14, 12);
    rightLayout->setSpacing(10);

    auto *hrBox = new QGroupBox("HEART RATE", right);
    hrBox->setMinimumHeight(140);
    auto *hrLayout = new QVBoxLayout(hrBox);
    hrLayout->setContentsMargins(12, 12, 12, 12);
    bpmLabel_ = new QLabel("72", hrBox);
    bpmLabel_->setAlignment(Qt::AlignCenter);
    bpmLabel_->setStyleSheet(QString("font-size:46px;font-weight:700;color:%1;").arg(kTrace));
    auto *bpmUnit = new QLabel("BPM", hrBox);
    bpmUnit->setAlignment(Qt::AlignCenter);
    bpmUnit->setStyleSheet(QString("color:%1;font-size:11px;font-weight:600;").arg(kMuted));
    hrLayout->addStretch(1);
    hrLayout->addWidget(bpmLabel_);
    hrLayout->addWidget(bpmUnit);
    hrLayout->addStretch(1);
    rightLayout->addWidget(hrBox);

    // Classification card: result first, implementation status second.
    // This mirrors the HEART RATE card instead of exposing a long runtime log.
    auto *aiBox = new QGroupBox("AI CLASSIFICATION", right);
    aiBox->setMinimumHeight(205);
    auto *aiLayout = new QVBoxLayout(aiBox);
    aiLayout->setContentsMargins(12, 12, 12, 12);
    aiLayout->setSpacing(8);

    auto *backendRow = new QHBoxLayout();
    backendRow->setSpacing(6);
    auto *backendTitle = new QLabel("INTERFACE", aiBox);
    backendTitle->setStyleSheet(QString("color:%1;font-size:10px;font-weight:700;").arg(kMuted));
    backendButtons_ = new QButtonGroup(this);
    backendButtons_->setExclusive(true);
    const QStringList backendNames = {"RTL", "CPU", "DPU"};
    for (int i = 0; i < backendNames.size(); ++i)
    {
        auto *button = new QPushButton(backendNames[i], aiBox);
        button->setCheckable(true);
        button->setProperty("backendSelector", true);
        backendButtons_->addButton(button, i);
        backendRow->addWidget(button);
    }
    if (auto *cpuButton = backendButtons_->button(1)) cpuButton->setChecked(true);
    backendRow->insertWidget(0, backendTitle);
    backendRow->insertStretch(1, 1);
    aiLayout->addLayout(backendRow);

    auto *predictionRow = new QHBoxLayout();
    predictionRow->setSpacing(12);
    predictionCodeLabel_ = new QLabel("—", aiBox);
    predictionCodeLabel_->setFixedWidth(58);
    predictionCodeLabel_->setAlignment(Qt::AlignCenter);
    predictionCodeLabel_->setStyleSheet(QString("font-size:38px;font-weight:800;color:%1;").arg(kMuted));

    auto *predictionText = new QVBoxLayout();
    predictionText->setSpacing(3);
    predictionLabel_ = new QLabel("Waiting for beat", aiBox);
    predictionLabel_->setWordWrap(true);
    predictionLabel_->setStyleSheet("font-size:15px;font-weight:700;");
    confidenceLabel_ = new QLabel("Confidence —", aiBox);
    confidenceLabel_->setStyleSheet(QString("color:%1;font-size:11px;").arg(kMuted));
    predictionText->addWidget(predictionLabel_);
    predictionText->addWidget(confidenceLabel_);
    predictionRow->addWidget(predictionCodeLabel_, 0, Qt::AlignVCenter);
    predictionRow->addLayout(predictionText, 1);
    aiLayout->addLayout(predictionRow);

    auto *separator = new QFrame(aiBox);
    separator->setFrameShape(QFrame::HLine);
    separator->setStyleSheet("color:#183022;background:#183022;max-height:1px;");
    aiLayout->addWidget(separator);

    auto *runtimeRow = new QHBoxLayout();
    auto *runtimeTitle = new QLabel("INFERENCE", aiBox);
    runtimeTitle->setStyleSheet(QString("color:%1;font-size:10px;font-weight:700;").arg(kMuted));
    runtimeLabel_ = new QLabel("INITIALIZING", aiBox);
    runtimeLabel_->setAlignment(Qt::AlignCenter);
    runtimeLabel_->setStyleSheet(QString(
        "color:%1;background:#102019;border:1px solid #254433;border-radius:9px;"
        "padding:3px 9px;font-size:10px;font-weight:700;").arg(kMuted));
    runtimeRow->addWidget(runtimeTitle);
    runtimeRow->addStretch(1);
    runtimeRow->addWidget(runtimeLabel_);
    aiLayout->addLayout(runtimeRow);
    rightLayout->addWidget(aiBox);

    auto *recentLabel = new QLabel("RECENT BEATS", right);
    recentLabel->setStyleSheet(QString("color:%1;font-size:11px;font-weight:700;padding:2px 2px 0 2px;").arg(kMuted));
    rightLayout->addWidget(recentLabel);

    historyTable_ = new QTableWidget(0, 4, right);
    historyTable_->setHorizontalHeaderLabels({"BEAT", "TIME", "CLASS", "CONF."});
    historyTable_->verticalHeader()->setVisible(false);
    historyTable_->verticalHeader()->setDefaultSectionSize(kHistoryRowHeight);
    historyTable_->verticalHeader()->setSectionResizeMode(QHeaderView::Fixed);
    historyTable_->horizontalHeader()->setFixedHeight(26);
    historyTable_->horizontalHeader()->setStretchLastSection(true);
    historyTable_->setEditTriggers(QAbstractItemView::NoEditTriggers);
    historyTable_->setSelectionMode(QAbstractItemView::NoSelection);
    historyTable_->setVerticalScrollBarPolicy(Qt::ScrollBarAsNeeded);
    historyTable_->setFixedHeight(historyTable_->horizontalHeader()->height() +
                                  kHistoryVisibleRows * kHistoryRowHeight + 2 * historyTable_->frameWidth());
    historyTable_->setAlternatingRowColors(true);
    rightLayout->addWidget(historyTable_, 1);

    auto *modeBox = new QGroupBox("RHYTHM PATTERN", bottom);
    auto *modeLayout = new QVBoxLayout(modeBox);
    modeLayout->setContentsMargins(10, 10, 10, 8);
    modeLayout->setSpacing(4);
    classCodeLabel_ = new QLabel("N", modeBox);
    classCodeLabel_->setStyleSheet(QString("font-size:28px;font-weight:700;color:%1;").arg(kTrace));
    classNameLabel_ = new QLabel("Normal / non-ectopic", modeBox);
    classNameLabel_->setWordWrap(true);
    classNameLabel_->setStyleSheet("font-weight:600;");
    modeLayout->addWidget(classCodeLabel_);
    modeLayout->addWidget(classNameLabel_);
    rhythmLabel_ = new QLabel("Regular sinus rhythm", modeBox);
    rhythmLabel_->setWordWrap(true);
    rhythmLabel_->setStyleSheet(QString("color:%1;font-size:10px;").arg(kMuted));
    modeLayout->addWidget(rhythmLabel_);

    auto *modeButtons = new QGridLayout();
    modeButtons->setContentsMargins(0, 4, 0, 0);
    modeButtons->setHorizontalSpacing(6);
    classButtons_ = new QButtonGroup(this);
    const QStringList codes = {"N", "S", "V", "F", "Q"};
    for (int i = 0; i < codes.size(); ++i)
    {
        auto *button = new QPushButton(codes[i], modeBox);
        button->setCheckable(true);
        button->setProperty("rhythmSelector", true);
        if (i == 0) button->setChecked(true);
        classButtons_->addButton(button, i);
        modeButtons->addWidget(button, 0, i);
    }
    modeLayout->addLayout(modeButtons);

    auto *controlsBox = new QGroupBox("SIMULATION CONTROLS", bottom);
    auto *controlsLayout = new QGridLayout(controlsBox);
    bpmSlider_ = new QSlider(Qt::Horizontal, controlsBox);
    bpmSlider_->setRange(40, 160);
    bpmSlider_->setValue(72);
    noiseSlider_ = new QSlider(Qt::Horizontal, controlsBox);
    noiseSlider_->setRange(0, 50);
    noiseSlider_->setValue(3);
    noiseLabel_ = new QLabel("0.003 rel. mV", controlsBox);
    controlsLayout->addWidget(new QLabel("Base BPM", controlsBox), 0, 0);
    controlsLayout->addWidget(bpmSlider_, 0, 1);
    controlsLayout->addWidget(new QLabel("Noise", controlsBox), 1, 0);
    controlsLayout->addWidget(noiseSlider_, 1, 1);
    controlsLayout->addWidget(noiseLabel_, 2, 1, 1, 1, Qt::AlignRight);

    // Nguong bao dong. Mac dinh 3 nhip nguy hiem; nguoi dung nang len 4, 5 hay 6
    // neu muon bot nhay.
    emergencyThresholdSpin_ = new QSpinBox(controlsBox);
    emergencyThresholdSpin_->setRange(1, 20);
    emergencyThresholdSpin_->setValue(3);
    emergencyThresholdSpin_->setSuffix(" beats");
    emergencyThresholdSpin_->setToolTip(
        QStringLiteral("Turn EMERGENCY red after this many S/V/F beats in the session.\n"
                       "N and Q are excluded: N is normal, and Q is unclassifiable or "
                       "paced, not an arrhythmia."));
    controlsLayout->addWidget(new QLabel("Emergency at", controlsBox), 3, 0);
    controlsLayout->addWidget(emergencyThresholdSpin_, 3, 1);

    auto *actionLayout = new QGridLayout();
    pauseButton_ = new QPushButton("PAUSE", bottom);
    auto *resetButton = new QPushButton("RESET", bottom);
    auto *exportButton = new QPushButton("EXPORT CSV", bottom);
    emergencyButton_ = new QPushButton("EMERGENCY", bottom);
    summaryButton_ = new QPushButton("REVIEW ABNORMAL · 0", bottom);
    summaryButton_->setFixedHeight(30);
    actionLayout->addWidget(pauseButton_, 0, 0);
    actionLayout->addWidget(resetButton, 0, 1);
    actionLayout->addWidget(exportButton, 1, 0);
    actionLayout->addWidget(emergencyButton_, 1, 1);
    actionLayout->addWidget(summaryButton_, 2, 0, 1, 2);

    // Sample count is still tracked for controller compatibility, but it is no
    // longer rendered as a persistent footnote in the product UI.
    sampleCountLabel_ = new QLabel(bottom);
    sampleCountLabel_->hide();

    auto *bottomLayout = new QGridLayout(bottom);
    bottomLayout->setContentsMargins(14, 8, 14, 8);
    bottomLayout->setHorizontalSpacing(12);
    bottomLayout->addWidget(modeBox, 0, 0);
    bottomLayout->addWidget(controlsBox, 0, 1);
    bottomLayout->addLayout(actionLayout, 0, 2);
    bottomLayout->setColumnStretch(0, 2);
    bottomLayout->setColumnStretch(1, 2);
    bottomLayout->setColumnStretch(2, 2);

    mainLayout->addWidget(left, 0, 0);
    mainLayout->addWidget(right, 0, 1);
    mainLayout->addWidget(bottom, 1, 0, 1, 2);
    mainLayout->setColumnStretch(0, 1);
    mainLayout->setRowStretch(0, 1);
    mainLayout->setRowStretch(1, 0);
    root->addWidget(main, 1);
    setCentralWidget(central);

    connect(classButtons_, QOverload<int>::of(&QButtonGroup::idClicked), this, &DemoWindow::modeChanged);
    connect(backendButtons_, QOverload<int>::of(&QButtonGroup::idClicked), this, &DemoWindow::backendChanged);
    connect(bpmSlider_, &QSlider::valueChanged, this, [this](const int value) {
        bpmLabel_->setText(QString::number(value));
        emit bpmChanged(static_cast<double>(value));
    });
    connect(noiseSlider_, &QSlider::valueChanged, this, [this](const int value) {
        const double noise = static_cast<double>(value) / 1000.0;
        noiseLabel_->setText(QString("%1 rel. mV").arg(noise, 0, 'f', 3));
        emit noiseChanged(noise);
    });
    connect(pauseButton_, &QPushButton::clicked, this, &DemoWindow::pauseRequested);
    connect(resetButton, &QPushButton::clicked, this, [this]() {
        if (historyTable_->rowCount() <= 0)
        {
            emit resetRequested();
            return;
        }
        const auto answer = QMessageBox::question(
            this,
            "Reset current session?",
            "This will clear the ECG history, AI event history, and review state for the current session.",
            QMessageBox::Cancel | QMessageBox::Reset,
            QMessageBox::Cancel);
        if (answer == QMessageBox::Reset) emit resetRequested();
    });
    connect(exportButton, &QPushButton::clicked, this, &DemoWindow::exportRequested);
    // Nut van phat tin hieu de sau nay co the noi vao mot co che canh bao that
    // su; hien tai no bao lai trang thai chu khong tu y gui di dau ca.
    connect(emergencyButton_, &QPushButton::clicked, this, [this]() {
        const int threshold = emergencyThresholdSpin_->value();
        if (criticalCount_ >= threshold)
        {
            showStatus(QString("EMERGENCY: %1 critical beats (S/V/F), threshold %2. "
                               "Open REVIEW ABNORMAL and escalate.")
                           .arg(criticalCount_).arg(threshold), true);
        }
        else
        {
            showStatus(QString("No emergency: %1 critical beats (S/V/F), threshold %2.")
                           .arg(criticalCount_).arg(threshold));
        }
        emit emergencyRequested();
    });
    connect(emergencyThresholdSpin_, QOverload<int>::of(&QSpinBox::valueChanged),
            this, [this](int) { refreshEmergencyState(); });
    connect(summaryButton_, &QPushButton::clicked, this, &DemoWindow::summaryRequested);

    clockTimer_ = new QTimer(this);
    connect(clockTimer_, &QTimer::timeout, this, &DemoWindow::updateClock);
    clockTimer_->start(250);
    updateClock();
}

void DemoWindow::configurePlot()
{
    plot_->setBackground(QBrush(QColor(kBg)));
    plot_->addGraph(); // line
    plot_->addGraph(); // points
    plot_->addGraph(); // R markers
    for (int classIndex = 1; classIndex < 5; ++classIndex)
    {
        plot_->addGraph(); // classified line overlay
        plot_->addGraph(); // classified points overlay
    }
    plot_->graph(0)->setPen(QPen(QColor(kTrace), 2));
    plot_->graph(1)->setLineStyle(QCPGraph::lsNone);
    plot_->graph(1)->setScatterStyle(QCPScatterStyle(QCPScatterStyle::ssCircle, QColor(kTrace), QColor(kTrace), 3));
    plot_->graph(2)->setLineStyle(QCPGraph::lsNone);
    plot_->graph(2)->setScatterStyle(QCPScatterStyle(QCPScatterStyle::ssDisc, QColor(kWarning), QColor(kWarning), 8));
    plot_->graph(2)->setName("R event");
    for (int classIndex = 1; classIndex < 5; ++classIndex)
    {
        const int lineGraph = 3 + (classIndex - 1) * 2;
        const int pointGraph = lineGraph + 1;
        const QColor color(classColor(classIndex));
        plot_->graph(lineGraph)->setLineStyle(QCPGraph::lsLine);
        plot_->graph(lineGraph)->setPen(QPen(color, 2));
        plot_->graph(pointGraph)->setLineStyle(QCPGraph::lsNone);
        plot_->graph(pointGraph)->setScatterStyle(QCPScatterStyle(QCPScatterStyle::ssCircle, color, color, 3));
        plot_->graph(lineGraph)->setVisible(false);
        plot_->graph(pointGraph)->setVisible(false);
    }
    plot_->legend->setVisible(false);
    plot_->axisRect()->setupFullAxesBox();
    plot_->xAxis->setLabel("Time (s)");
    plot_->yAxis->setLabel("Amplitude");
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
    plot_->yAxis->setRange(-1.6, 1.6);
    plot_->xAxis->setRange(0.0, kPlotWindowSeconds);
    plot_->setInteractions(QCP::iRangeDrag | QCP::iRangeZoom);

    cursorLine_ = new QCPItemLine(plot_);
    cursorLine_->setPen(QPen(QColor("#1F9E4F"), 2));
    cursorLine_->start->setCoords(0.0, -1.6);
    cursorLine_->end->setCoords(0.0, 1.6);
}

DemoWindow::RenderMode DemoWindow::renderMode() const
{
    return RenderMode::LineAndPoints;
}

DemoWindow::DisplayMode DemoWindow::displayMode() const
{
    return DisplayMode::Sweep;
}

bool DemoWindow::showProcessedSignal() const
{
    return true;
}

void DemoWindow::applyRenderMode()
{
    // The monitor has one fixed presentation: processed signal, sweep mode,
    // rendered as a line with points.
    plot_->graph(0)->setVisible(true);
    plot_->graph(1)->setVisible(true);
}

void DemoWindow::setPlotData(const QVector<double> &keys,
                             const QVector<double> &values,
                             const QVector<double> &rKeys,
                             const QVector<double> &rValues,
                             const QVector<int> &rClasses,
                             const QVector<float> &rConfidences,
                             const QVector<int> &sampleClasses,
                             const QVector<float> &sampleConfidences,
                             const double cursorKey,
                             const bool showCursor)
{
    plot_->graph(0)->setData(keys, values, true);
    plot_->graph(1)->setData(keys, values, true);
    plot_->graph(2)->setData(rKeys, rValues, true);

    // Paint only samples that the controller mapped to an AI-classified
    // abnormal beat. The mask is aligned with the circular sweep buffer, so a
    // V beat is colored across its complete displayed morphology (including
    // samples before the R peak) and does not leak into the following baseline.
    Q_UNUSED(rClasses);
    Q_UNUSED(rConfidences);
    for (int classIndex = 1; classIndex < 5; ++classIndex)
    {
        const int lineGraph = 3 + (classIndex - 1) * 2;
        const int pointGraph = lineGraph + 1;
        QVector<double> coloredValues(keys.size(), std::numeric_limits<double>::quiet_NaN());
        bool hasColor = false;
        double confidenceSum = 0.0;
        int confidenceCount = 0;
        for (int keyIndex = 0; keyIndex < keys.size(); ++keyIndex)
        {
            if (sampleClasses.value(keyIndex, -1) != classIndex)
            {
                continue;
            }

            const double value = values.value(keyIndex, std::numeric_limits<double>::quiet_NaN());
            if (!std::isfinite(value))
            {
                continue;
            }

            coloredValues[keyIndex] = value;
            hasColor = true;
            confidenceSum += sampleConfidences.value(keyIndex, 0.0f);
            ++confidenceCount;
        }
        plot_->graph(lineGraph)->setData(keys, coloredValues, true);
        plot_->graph(pointGraph)->setData(keys, coloredValues, true);
        plot_->graph(lineGraph)->setVisible(hasColor);
        plot_->graph(pointGraph)->setVisible(hasColor);
        if (hasColor)
        {
            const float confidence = confidenceCount > 0
                                         ? static_cast<float>(confidenceSum / confidenceCount)
                                         : 1.0f;
            QColor color(classColor(classIndex));
            color.setAlphaF(std::clamp(0.35f + 0.65f * confidence, 0.35f, 1.0f));
            plot_->graph(lineGraph)->setPen(QPen(color, 2));
            plot_->graph(pointGraph)->setScatterStyle(QCPScatterStyle(QCPScatterStyle::ssCircle, color, color, 3));
        }
    }

    if (displayMode() == DisplayMode::Sweep)
    {
        plot_->xAxis->setRange(0.0, kPlotWindowSeconds);
        plot_->yAxis->setRange(-1.6, 1.6);
    }
    else if (!keys.isEmpty())
    {
        plot_->xAxis->setRange(0.0, kPlotWindowSeconds);
        plot_->yAxis->setRange(-1.6, 1.6);
    }

    cursorLine_->setVisible(showCursor);
    if (showCursor)
    {
        cursorLine_->start->setCoords(cursorKey, -1.6);
        cursorLine_->end->setCoords(cursorKey, 1.6);
    }
    applyRenderMode();
    plot_->replot(QCustomPlot::rpQueuedReplot);
}

void DemoWindow::clearSession()
{
    for (int i = 0; i < plot_->graphCount(); ++i) plot_->graph(i)->data()->clear();
    historyTable_->setRowCount(0);
    predictionCodeLabel_->setText("—");
    predictionCodeLabel_->setStyleSheet(QString("font-size:38px;font-weight:800;color:%1;").arg(kMuted));
    predictionLabel_->setText("Waiting for beat");
    predictionLabel_->setStyleSheet(QString("font-size:15px;font-weight:700;color:%1;").arg(kText));
    confidenceLabel_->setText("Confidence —");
    sampleCountLabel_->setText("0");
    setClassCounts(QVector<int>(5, 0));
    criticalCount_ = 0;
    refreshEmergencyState();
    plot_->replot();
}

void DemoWindow::setRuntimeStatus(const QString &status, const bool ready)
{
    const QString lower = status.toLower();
    QString badge = "INFERENCE";
    if (lower.contains("rtl pl"))
    {
        badge = "RTL ACTIVE";
    }
    else if (lower.contains("vitis ai dpu"))
    {
        badge = "DPU ACTIVE";
    }
    else if (lower.contains("cpu"))
    {
        badge = "CPU ACTIVE";
    }

    if (!ready) badge = "INTERFACE OFFLINE";
    runtimeLabel_->setText(badge);
    runtimeLabel_->setToolTip(status);
    runtimeLabel_->setStyleSheet(QString(
        "color:%1;background:#102019;border:1px solid %2;border-radius:9px;"
        "padding:3px 9px;font-size:10px;font-weight:700;")
        .arg(ready ? kTrace : kWarning, ready ? "#285C3A" : "#6A5420"));
}

void DemoWindow::setBackendSelection(const int backendIndex)
{
    if (backendButtons_ == nullptr) return;
    if (auto *button = backendButtons_->button(backendIndex))
    {
        const bool blocked = backendButtons_->blockSignals(true);
        button->setChecked(true);
        backendButtons_->blockSignals(blocked);
    }
}

void DemoWindow::setBackendAvailability(const bool rtlAvailable,
                                        const bool cpuAvailable,
                                        const bool dpuAvailable)
{
    if (backendButtons_ == nullptr) return;
    const bool available[] = {rtlAvailable, cpuAvailable, dpuAvailable};
    const QString unavailableTips[] = {
        "RTL interface is available on the Linux/KV260 build after the PL host is prepared.",
        "CPU interface is unavailable in this build.",
        "DPU interface requires a build with Vitis AI enabled."};
    for (int i = 0; i < 3; ++i)
    {
        if (auto *button = backendButtons_->button(i))
        {
            button->setEnabled(available[i]);
            if (!available[i]) button->setToolTip(unavailableTips[i]);
        }
    }
}

void DemoWindow::setLiveState(const bool running)
{
    liveLabel_->setText(running ? "● LIVE" : "● PAUSED");
    liveLabel_->setStyleSheet(QString("color:%1;font-size:14px;font-weight:700;").arg(running ? kTrace : kWarning));
    pauseButton_->setText(running ? "PAUSE" : "RESUME");
}

void DemoWindow::setModeInfo(const int classIndex,
                             const QString &sourceFile,
                             const QString &description,
                             const int defaultBpm)
{
    Q_UNUSED(sourceFile);
    classCodeLabel_->setText(ecgClassShortName(classIndex));
    classCodeLabel_->setStyleSheet(QString("font-size:28px;font-weight:700;color:%1;").arg(classColor(classIndex)));
    classNameLabel_->setText(ecgClassLongName(classIndex));
    rhythmLabel_->setText(description);
    bpmSlider_->setValue(defaultBpm);
}

void DemoWindow::setHeartRate(const double bpm)
{
    bpmLabel_->setText(QString::number(static_cast<int>(std::lround(bpm))));
}

void DemoWindow::setSampleCount(const qint64 count)
{
    sampleCountLabel_->setText(QString::number(count));
}

void DemoWindow::setExpectedBeat(const int beatIndex, const int truthClass, const double timeSeconds)
{
    predictionCodeLabel_->setText("—");
    predictionCodeLabel_->setStyleSheet(QString("font-size:38px;font-weight:800;color:%1;").arg(kMuted));
    predictionLabel_->setText("Classification unavailable");
    predictionLabel_->setStyleSheet(QString("font-size:15px;font-weight:700;color:%1;").arg(kText));
    confidenceLabel_->setText("Confidence —");

    historyTable_->insertRow(0);
    const QStringList cells = {
        QString::number(beatIndex),
        QString::number(timeSeconds, 'f', 2) + " s",
        ecgClassShortName(truthClass),
        "—"};
    for (int col = 0; col < cells.size(); ++col)
    {
        auto *item = new QTableWidgetItem(cells[col]);
        item->setTextAlignment(Qt::AlignCenter);
        historyTable_->setItem(0, col, item);
    }
}

void DemoWindow::setPrediction(const AiBeatResult &result,
                               const int truthClass,
                               const int correct,
                               const int predictedTotal)
{
    if (!result.valid) return;
    const QString color = classColor(result.classIndex);
    predictionCodeLabel_->setText(result.label);
    predictionCodeLabel_->setStyleSheet(QString("font-size:38px;font-weight:800;color:%1;").arg(color));
    predictionLabel_->setText(ecgClassLongName(result.classIndex));
    predictionLabel_->setStyleSheet(QString("font-size:15px;font-weight:700;color:%1;").arg(color));
    confidenceLabel_->setText(QString("Confidence %1%").arg(result.confidence * 100.0f, 0, 'f', 1));
    Q_UNUSED(truthClass);
    Q_UNUSED(correct);
    Q_UNUSED(predictedTotal);

    historyTable_->insertRow(0);
    const QStringList cells = {
        QString::number(result.beatIndex),
        QString::number(result.timeSeconds, 'f', 2) + " s",
        result.label,
        QString::number(result.confidence * 100.0f, 'f', 1) + "%"};
    for (int col = 0; col < cells.size(); ++col)
    {
        auto *item = new QTableWidgetItem(cells[col]);
        item->setTextAlignment(Qt::AlignCenter);
        historyTable_->setItem(0, col, item);
    }
}

void DemoWindow::showSummary(const QVector<HistoryRecord> &history,
                             const QVector<int> &eventCounts)
{
    updateReviewData(history, eventCounts);
    if (reviewWindow_ == nullptr)
    {
        reviewWindow_ = new AbnormalReviewWindow(this);
        connect(reviewWindow_, &AbnormalReviewWindow::reviewStateChanged,
                this, &DemoWindow::reviewStateChanged);
    }

    reviewWindow_->setData(history, eventCounts, liveLabel_->text().contains("LIVE"));
    reviewWindow_->show();
    reviewWindow_->raise();
    reviewWindow_->activateWindow();
}

void DemoWindow::refreshEmergencyState()
{
    if (emergencyButton_ == nullptr) return;

    const int threshold = emergencyThresholdSpin_ != nullptr
                              ? emergencyThresholdSpin_->value()
                              : 3;
    const bool alarm = criticalCount_ >= threshold;

    emergencyButton_->setText(criticalCount_ > 0
                                  ? QString("EMERGENCY · %1/%2").arg(criticalCount_).arg(threshold)
                                  : QString("EMERGENCY"));

    // Qt chi ap dung lai stylesheet khi widget duoc unpolish/polish, nen doi
    // thuoc tinh khong thoi se khong doi mau.
    if (emergencyButton_->property("alarm").toBool() != alarm)
    {
        emergencyButton_->setProperty("alarm", alarm);
        emergencyButton_->style()->unpolish(emergencyButton_);
        emergencyButton_->style()->polish(emergencyButton_);
    }
    emergencyButton_->update();
}

void DemoWindow::updateReviewData(const QVector<HistoryRecord> &history,
                                  const QVector<int> &eventCounts)
{
    // Hai phep dem khac nhau va deu can thiet.
    //
    // reportedAbnormal la moi nhip khong phai N, dung cho nut REVIEW ABNORMAL.
    //
    // criticalCount_ chi dem S, V va F. Lop Q bi loai vi no la nhip khong phan
    // loai duoc hoac nhip may tao nhip, khong phai roi loan nhip; gop Q vao se
    // lam bao dong keu len vi mot thu khong co y nghia lam sang.
    int reportedAbnormal = 0;
    int critical = 0;
    for (const HistoryRecord &record : history)
    {
        if (!record.result.valid) continue;
        const int classIndex = record.result.classIndex;
        if (classIndex > 0) ++reportedAbnormal;
        if (classIndex >= 1 && classIndex <= 3) ++critical;   // S, V, F
    }
    criticalCount_ = critical;
    refreshEmergencyState();
    summaryButton_->setText(QString("REVIEW ABNORMAL · %1").arg(reportedAbnormal));
    summaryButton_->setProperty("hasEvents", reportedAbnormal > 0);
    summaryButton_->style()->unpolish(summaryButton_);
    summaryButton_->style()->polish(summaryButton_);

    if (reviewWindow_ == nullptr || !reviewWindow_->isVisible()) return;
    reviewWindow_->setData(history, eventCounts, liveLabel_->text().contains("LIVE"));
}

void DemoWindow::setClassCounts(const QVector<int> &eventCounts)
{
    Q_UNUSED(eventCounts);
}

void DemoWindow::showStatus(const QString &text, const bool warning)
{
    if (text.trimmed().isEmpty())
    {
        statusLabel_->clear();
        statusLabel_->hide();
        return;
    }

    // Do not use the main screen as a technical log. Normal initialization is
    // intentionally silent; only actionable feedback is surfaced.
    if (!warning && (text == "ECG data ready" || text.startsWith("Loaded N/S/V/F/Q")))
    {
        statusLabel_->clear();
        statusLabel_->hide();
        return;
    }

    QString displayText = text;
    if (!warning && text.startsWith("Exported visible"))
    {
        displayText = "CSV export complete";
        statusLabel_->setToolTip(text);
    }
    else
    {
        statusLabel_->setToolTip(QString());
    }

    statusLabel_->setText(displayText);
    statusLabel_->setStyleSheet(QString("color:%1;font-size:10px;").arg(warning ? kWarning : kMuted));
    statusLabel_->show();
}

void DemoWindow::updateClock()
{
    clockLabel_->setText(QDateTime::currentDateTime().toString("HH:mm:ss"));
}

QString DemoWindow::classColor(const int classIndex) const
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
