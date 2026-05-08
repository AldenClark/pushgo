#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const fixtureDir = path.resolve("pushgo/Tests/Fixtures/p2");

const locales = [
  { code: "en", locale: "en_US" },
  { code: "de", locale: "de_DE" },
  { code: "es", locale: "es_ES" },
  { code: "fr", locale: "fr_FR" },
  { code: "ja", locale: "ja_JP" },
  { code: "ko", locale: "ko_KR" },
  { code: "zh-CN", locale: "zh_CN" },
  { code: "zh-TW", locale: "zh_TW" },
];

const copy = {
  en: {
    languageName: "English",
    channelWord: "Channel",
    scenarios: {
      ops: "Server Operations",
      home: "Smart Home",
      finance: "Finance Ledger",
      monitor: "Event Monitoring",
      ai: "AI Agent Feedback",
    },
    eventNames: {
      latency: "Gateway latency spike",
      packet: "Packet loss anomaly",
      disk: "Storage saturation warning",
      tls: "TLS certificate expiry risk",
      policy: "Policy execution drift",
      hvac: "HVAC coordination conflict",
      water: "Water leak sensor alarm",
      entry: "Unexpected access event",
      power: "Power relay instability",
      battery: "Low battery degradation",
      transfer: "Unexpected transfer detected",
      fx: "FX loss threshold reached",
      cashflow: "Cashflow drawdown warning",
      invoice: "Delayed invoice settlement",
      payroll: "Payroll variance alert",
      api: "API error ratio surge",
      crawler: "Crawler timeout burst",
      webhook: "Webhook retry storm",
      cpu: "CPU thermal throttling",
      queue: "Event queue backlog",
      tool: "Tool chain step timeout",
      token: "Token cost anomaly",
      memory: "Context memory overflow",
      approval: "Approval SLA breach",
      hallucination: "Fact-verification miss",
    },
    statuses: {
      detected: "Detected",
      investigating: "Investigating",
      resolved: "Resolved",
    },
    stages: {
      detected: "initial detection",
      investigating: "active triage",
      resolved: "recovery closed",
    },
    sections: {
      summary: "Summary",
      signals: "Current Signals",
      timeline: "Action Timeline",
      next: "Next 30 Minutes",
      links: "Reference",
    },
    phrases: {
      metadataOwner: "On-call owner",
      metadataRunbook: "Runbook",
      metadataRegion: "Region",
      attrEnvironment: "environment",
      attrWindow: "maintenance_window",
      attrRecovery: "recovery_strategy",
      attrImpact: "impact_scope",
      attrChanges: "attribute changes",
      changeFrom: "from",
      changeTo: "to",
      briefTitle: "Executive brief",
      objectTitle: "Object update",
      eventTitle: "Event update",
      bodyImpact: "User-facing impact is controlled, no hard outage reported.",
      bodyRisk: "Primary risk is secondary cascade if mitigation is delayed.",
      bodyAction: "Mitigation owner acknowledged and ETA is within SLA.",
      bodyResolved: "Recovery checks passed and rollback plan remains ready.",
      screenshotNote: "Screenshot fixture generated for App Store localization.",
    },
  },
  de: {
    languageName: "Deutsch",
    channelWord: "Kanal",
    scenarios: {
      ops: "Serverbetrieb",
      home: "Smart Home",
      finance: "Finanzbuch",
      monitor: "Ereignisüberwachung",
      ai: "KI-Agent Feedback",
    },
    eventNames: {
      latency: "Latenzspitze am Gateway",
      packet: "Anomalie bei Paketverlust",
      disk: "Warnung Speicherauslastung",
      tls: "Risiko Zertifikatsablauf",
      policy: "Abweichung Richtlinienausführung",
      hvac: "HVAC-Koordinationskonflikt",
      water: "Wassersensor-Alarm",
      entry: "Unerwarteter Zutritt",
      power: "Instabilität Stromrelais",
      battery: "Warnung Batteriezustand",
      transfer: "Unerwartete Überweisung",
      fx: "FX-Verlustschwelle erreicht",
      cashflow: "Warnung Cashflow-Rückgang",
      invoice: "Verspätete Rechnungszahlung",
      payroll: "Abweichung Gehaltslauf",
      api: "Anstieg API-Fehlerquote",
      crawler: "Crawler-Timeout-Serie",
      webhook: "Webhook-Retry-Sturm",
      cpu: "CPU-Thermal-Drosselung",
      queue: "Rückstau Ereigniswarteschlange",
      tool: "Timeout Tool-Chain Schritt",
      token: "Anomalie Token-Kosten",
      memory: "Kontextspeicher Überlauf",
      approval: "SLA-Verstoß Freigabe",
      hallucination: "Fehler Faktenprüfung",
    },
    statuses: {
      detected: "Erkannt",
      investigating: "In Analyse",
      resolved: "Gelöst",
    },
    stages: {
      detected: "Ersterkennung",
      investigating: "laufende Analyse",
      resolved: "Wiederherstellung abgeschlossen",
    },
    sections: {
      summary: "Zusammenfassung",
      signals: "Aktuelle Signale",
      timeline: "Aktionsverlauf",
      next: "Nächste 30 Minuten",
      links: "Referenz",
    },
    phrases: {
      metadataOwner: "Bereitschaftsverantwortlicher",
      metadataRunbook: "Runbook",
      metadataRegion: "Region",
      attrEnvironment: "umgebung",
      attrWindow: "wartungsfenster",
      attrRecovery: "wiederherstellungsstrategie",
      attrImpact: "auswirkungsbereich",
      attrChanges: "Attributänderungen",
      changeFrom: "von",
      changeTo: "auf",
      briefTitle: "Management-Überblick",
      objectTitle: "Objekt-Update",
      eventTitle: "Ereignis-Update",
      bodyImpact: "Nutzerwirkung ist begrenzt, kein harter Ausfall gemeldet.",
      bodyRisk: "Hauptrisiko ist eine Folgekaskade bei verzögerter Gegenmaßnahme.",
      bodyAction: "Verantwortlicher hat bestätigt, ETA liegt innerhalb der SLA.",
      bodyResolved: "Recovery-Checks bestanden, Rollback bleibt vorbereitet.",
      screenshotNote: "Screenshot-Fixture für App-Store-Lokalisierung erstellt.",
    },
  },
  es: {
    languageName: "Español",
    channelWord: "Canal",
    scenarios: {
      ops: "Operación de Servidores",
      home: "Hogar Inteligente",
      finance: "Libro Financiero",
      monitor: "Monitoreo de Eventos",
      ai: "Feedback de Agentes IA",
    },
    eventNames: {
      latency: "Pico de latencia en gateway",
      packet: "Anomalía de pérdida de paquetes",
      disk: "Advertencia de saturación de almacenamiento",
      tls: "Riesgo de vencimiento de certificado TLS",
      policy: "Desvío en ejecución de políticas",
      hvac: "Conflicto de coordinación HVAC",
      water: "Alarma de fuga de agua",
      entry: "Evento de acceso inesperado",
      power: "Inestabilidad en relé eléctrico",
      battery: "Degradación de batería baja",
      transfer: "Transferencia inesperada detectada",
      fx: "Umbral de pérdida FX alcanzado",
      cashflow: "Advertencia de caída de flujo de caja",
      invoice: "Liquidación de factura retrasada",
      payroll: "Alerta de variación de nómina",
      api: "Aumento de ratio de error API",
      crawler: "Ráfaga de timeout de crawler",
      webhook: "Tormenta de reintentos webhook",
      cpu: "Estrangulamiento térmico de CPU",
      queue: "Acumulación en cola de eventos",
      tool: "Timeout en paso de herramienta",
      token: "Anomalía de costo de token",
      memory: "Desbordamiento de memoria de contexto",
      approval: "Incumplimiento SLA de aprobación",
      hallucination: "Falla de verificación factual",
    },
    statuses: {
      detected: "Detectado",
      investigating: "Investigando",
      resolved: "Resuelto",
    },
    stages: {
      detected: "detección inicial",
      investigating: "triaje activo",
      resolved: "recuperación cerrada",
    },
    sections: {
      summary: "Resumen",
      signals: "Señales actuales",
      timeline: "Línea de acción",
      next: "Próximos 30 minutos",
      links: "Referencia",
    },
    phrases: {
      metadataOwner: "Responsable de guardia",
      metadataRunbook: "Runbook",
      metadataRegion: "Región",
      attrEnvironment: "entorno",
      attrWindow: "ventana_mantenimiento",
      attrRecovery: "estrategia_recuperacion",
      attrImpact: "alcance_impacto",
      attrChanges: "cambios de atributos",
      changeFrom: "de",
      changeTo: "a",
      briefTitle: "Resumen ejecutivo",
      objectTitle: "Actualización de objeto",
      eventTitle: "Actualización de evento",
      bodyImpact: "El impacto al usuario está controlado, sin caída total reportada.",
      bodyRisk: "El riesgo principal es un efecto cascada si se retrasa la mitigación.",
      bodyAction: "El responsable confirmó la mitigación y ETA dentro de SLA.",
      bodyResolved: "Validaciones de recuperación correctas y rollback listo.",
      screenshotNote: "Fixture de capturas generado para localización en App Store.",
    },
  },
  fr: {
    languageName: "Français",
    channelWord: "Canal",
    scenarios: {
      ops: "Exploitation Serveur",
      home: "Maison Intelligente",
      finance: "Registre Financier",
      monitor: "Supervision d'Événements",
      ai: "Retour Agent IA",
    },
    eventNames: {
      latency: "Pic de latence gateway",
      packet: "Anomalie de perte de paquets",
      disk: "Alerte saturation stockage",
      tls: "Risque expiration certificat TLS",
      policy: "Écart d'exécution de politique",
      hvac: "Conflit de coordination CVC",
      water: "Alerte capteur de fuite d'eau",
      entry: "Accès inattendu détecté",
      power: "Instabilité du relais électrique",
      battery: "Dégradation batterie faible",
      transfer: "Transfert inattendu détecté",
      fx: "Seuil de perte FX atteint",
      cashflow: "Alerte baisse de trésorerie",
      invoice: "Règlement facture retardé",
      payroll: "Alerte écart de paie",
      api: "Hausse du taux d'erreur API",
      crawler: "Rafale de timeout crawler",
      webhook: "Tempête de retry webhook",
      cpu: "Bridage thermique CPU",
      queue: "Arriéré file d'événements",
      tool: "Timeout étape chaîne outil",
      token: "Anomalie coût token",
      memory: "Débordement mémoire de contexte",
      approval: "Violation SLA d'approbation",
      hallucination: "Échec vérification factuelle",
    },
    statuses: {
      detected: "Détecté",
      investigating: "Investigation",
      resolved: "Résolu",
    },
    stages: {
      detected: "détection initiale",
      investigating: "triage actif",
      resolved: "rétablissement clôturé",
    },
    sections: {
      summary: "Résumé",
      signals: "Signaux actuels",
      timeline: "Chronologie d'action",
      next: "Prochaines 30 minutes",
      links: "Référence",
    },
    phrases: {
      metadataOwner: "Responsable astreinte",
      metadataRunbook: "Runbook",
      metadataRegion: "Région",
      attrEnvironment: "environnement",
      attrWindow: "fenetre_maintenance",
      attrRecovery: "strategie_reprise",
      attrImpact: "portee_impact",
      attrChanges: "modifications attributs",
      changeFrom: "de",
      changeTo: "vers",
      briefTitle: "Brief exécutif",
      objectTitle: "Mise à jour objet",
      eventTitle: "Mise à jour événement",
      bodyImpact: "Impact utilisateur maîtrisé, aucune indisponibilité totale signalée.",
      bodyRisk: "Le risque principal est une cascade secondaire si la mitigation tarde.",
      bodyAction: "Le responsable a confirmé, ETA dans la SLA.",
      bodyResolved: "Contrôles de reprise validés, rollback prêt.",
      screenshotNote: "Fixture de captures généré pour la localisation App Store.",
    },
  },
  ja: {
    languageName: "日本語",
    channelWord: "チャンネル",
    scenarios: {
      ops: "サーバー運用",
      home: "スマートホーム",
      finance: "財務台帳",
      monitor: "イベント監視",
      ai: "AIエージェント報告",
    },
    eventNames: {
      latency: "ゲートウェイ遅延スパイク",
      packet: "パケット損失異常",
      disk: "ストレージ逼迫警告",
      tls: "TLS証明書期限切れリスク",
      policy: "ポリシー実行ドリフト",
      hvac: "空調連携コンフリクト",
      water: "漏水センサー警報",
      entry: "予期しない入室イベント",
      power: "電源リレー不安定",
      battery: "バッテリー劣化警告",
      transfer: "不審な送金検出",
      fx: "為替損失しきい値到達",
      cashflow: "キャッシュフロー低下警告",
      invoice: "請求入金遅延",
      payroll: "給与差異アラート",
      api: "APIエラー率急増",
      crawler: "クローラータイムアウト連発",
      webhook: "Webhook再試行ストーム",
      cpu: "CPU熱スロットリング",
      queue: "イベントキュー滞留",
      tool: "ツールチェーン工程タイムアウト",
      token: "トークンコスト異常",
      memory: "コンテキストメモリ飽和",
      approval: "承認SLA違反",
      hallucination: "事実検証ミス",
    },
    statuses: {
      detected: "検知",
      investigating: "調査中",
      resolved: "解消",
    },
    stages: {
      detected: "初期検知",
      investigating: "対応中",
      resolved: "復旧完了",
    },
    sections: {
      summary: "概要",
      signals: "現在のシグナル",
      timeline: "対応タイムライン",
      next: "今後30分の計画",
      links: "参照",
    },
    phrases: {
      metadataOwner: "当番担当",
      metadataRunbook: "ランブック",
      metadataRegion: "リージョン",
      attrEnvironment: "環境",
      attrWindow: "メンテナンス時間帯",
      attrRecovery: "復旧戦略",
      attrImpact: "影響範囲",
      attrChanges: "属性変更",
      changeFrom: "変更前",
      changeTo: "変更後",
      briefTitle: "経営向けサマリー",
      objectTitle: "オブジェクト更新",
      eventTitle: "イベント更新",
      bodyImpact: "ユーザー影響は限定的で、重大停止は発生していません。",
      bodyRisk: "主なリスクは、対処遅延時の二次障害連鎖です。",
      bodyAction: "担当者は対策を受領済みで、ETAはSLA内です。",
      bodyResolved: "復旧確認は完了し、ロールバック計画も維持されています。",
      screenshotNote: "App Storeローカライズ向けスクリーンショット用 fixture を生成。",
    },
  },
  ko: {
    languageName: "한국어",
    channelWord: "채널",
    scenarios: {
      ops: "서버 운영",
      home: "스마트 홈",
      finance: "재무 원장",
      monitor: "이벤트 모니터링",
      ai: "AI 에이전트 피드백",
    },
    eventNames: {
      latency: "게이트웨이 지연 급증",
      packet: "패킷 손실 이상",
      disk: "스토리지 포화 경고",
      tls: "TLS 인증서 만료 위험",
      policy: "정책 실행 편차",
      hvac: "HVAC 연동 충돌",
      water: "누수 센서 경보",
      entry: "비정상 출입 이벤트",
      power: "전원 릴레이 불안정",
      battery: "배터리 성능 저하",
      transfer: "의심 이체 감지",
      fx: "환율 손실 임계치 도달",
      cashflow: "현금흐름 하락 경고",
      invoice: "청구 정산 지연",
      payroll: "급여 편차 알림",
      api: "API 오류율 급증",
      crawler: "크롤러 타임아웃 급증",
      webhook: "Webhook 재시도 폭주",
      cpu: "CPU 열 스로틀링",
      queue: "이벤트 큐 적체",
      tool: "툴체인 단계 타임아웃",
      token: "토큰 비용 이상",
      memory: "컨텍스트 메모리 과부하",
      approval: "승인 SLA 위반",
      hallucination: "사실 검증 누락",
    },
    statuses: {
      detected: "감지",
      investigating: "조사 중",
      resolved: "해결",
    },
    stages: {
      detected: "초기 감지",
      investigating: "대응 진행",
      resolved: "복구 종료",
    },
    sections: {
      summary: "요약",
      signals: "현재 신호",
      timeline: "조치 타임라인",
      next: "향후 30분 계획",
      links: "참고",
    },
    phrases: {
      metadataOwner: "온콜 담당자",
      metadataRunbook: "런북",
      metadataRegion: "리전",
      attrEnvironment: "환경",
      attrWindow: "점검_윈도우",
      attrRecovery: "복구_전략",
      attrImpact: "영향_범위",
      attrChanges: "속성 변경",
      changeFrom: "이전",
      changeTo: "이후",
      briefTitle: "경영 요약",
      objectTitle: "객체 업데이트",
      eventTitle: "이벤트 업데이트",
      bodyImpact: "사용자 영향은 통제 중이며 치명적 장애는 없습니다.",
      bodyRisk: "완화가 지연되면 2차 연쇄 장애가 핵심 위험입니다.",
      bodyAction: "담당자가 조치를 수락했고 ETA는 SLA 이내입니다.",
      bodyResolved: "복구 점검 완료, 롤백 계획도 준비 상태입니다.",
      screenshotNote: "App Store 현지화용 스크린샷 fixture 생성 완료.",
    },
  },
  "zh-CN": {
    languageName: "简体中文",
    channelWord: "频道",
    scenarios: {
      ops: "服务器运维",
      home: "智能家居",
      finance: "财务变动",
      monitor: "事件监控",
      ai: "AI Agent 工作反馈",
    },
    eventNames: {
      latency: "网关延迟突增",
      packet: "链路丢包异常",
      disk: "存储容量逼近阈值",
      tls: "TLS 证书到期风险",
      policy: "策略执行偏差",
      hvac: "空调联动冲突",
      water: "漏水传感器告警",
      entry: "异常门禁事件",
      power: "电源继电器不稳定",
      battery: "电池健康度下滑",
      transfer: "异常转账检测",
      fx: "汇率损失阈值触发",
      cashflow: "现金流回撤预警",
      invoice: "应收结算延迟",
      payroll: "薪资波动告警",
      api: "API 错误率飙升",
      crawler: "采集器超时爆发",
      webhook: "Webhook 重试风暴",
      cpu: "CPU 热降频告警",
      queue: "事件队列积压",
      tool: "工具链步骤超时",
      token: "Token 成本异常",
      memory: "上下文内存溢出风险",
      approval: "审批 SLA 超时",
      hallucination: "事实校验漏检",
    },
    statuses: {
      detected: "触发检测",
      investigating: "定位处理中",
      resolved: "恢复关闭",
    },
    stages: {
      detected: "首次触发",
      investigating: "处置进行中",
      resolved: "已恢复并关闭",
    },
    sections: {
      summary: "摘要",
      signals: "当前信号",
      timeline: "处置时间线",
      next: "未来 30 分钟计划",
      links: "参考信息",
    },
    phrases: {
      metadataOwner: "值班负责人",
      metadataRunbook: "处置手册",
      metadataRegion: "区域",
      attrEnvironment: "环境",
      attrWindow: "维护窗口",
      attrRecovery: "恢复策略",
      attrImpact: "影响范围",
      attrChanges: "属性变更",
      changeFrom: "从",
      changeTo: "到",
      briefTitle: "管理层简报",
      objectTitle: "对象更新",
      eventTitle: "事件更新",
      bodyImpact: "用户侧影响已控制，未出现硬中断。",
      bodyRisk: "主要风险为处置延迟引发二次级联故障。",
      bodyAction: "责任人已确认执行，预计完成时间在 SLA 内。",
      bodyResolved: "恢复检查通过，回滚方案保持就绪。",
      screenshotNote: "用于 App Store 多语言截图的演示数据。",
    },
  },
  "zh-TW": {
    languageName: "繁體中文",
    channelWord: "頻道",
    scenarios: {
      ops: "伺服器維運",
      home: "智慧家庭",
      finance: "財務變動",
      monitor: "事件監控",
      ai: "AI Agent 工作回饋",
    },
    eventNames: {
      latency: "閘道延遲突增",
      packet: "鏈路封包遺失異常",
      disk: "儲存容量逼近門檻",
      tls: "TLS 憑證到期風險",
      policy: "策略執行偏差",
      hvac: "空調連動衝突",
      water: "漏水感測警報",
      entry: "異常門禁事件",
      power: "電源繼電器不穩定",
      battery: "電池健康度下滑",
      transfer: "異常轉帳偵測",
      fx: "匯率損失門檻觸發",
      cashflow: "現金流回撤預警",
      invoice: "應收結算延遲",
      payroll: "薪資波動告警",
      api: "API 錯誤率飆升",
      crawler: "採集器逾時暴增",
      webhook: "Webhook 重試風暴",
      cpu: "CPU 熱降頻警示",
      queue: "事件佇列積壓",
      tool: "工具鏈步驟逾時",
      token: "Token 成本異常",
      memory: "上下文記憶體溢位風險",
      approval: "審批 SLA 逾時",
      hallucination: "事實校驗漏檢",
    },
    statuses: {
      detected: "觸發偵測",
      investigating: "定位處理中",
      resolved: "恢復關閉",
    },
    stages: {
      detected: "首次觸發",
      investigating: "處置進行中",
      resolved: "已恢復並關閉",
    },
    sections: {
      summary: "摘要",
      signals: "目前訊號",
      timeline: "處置時間線",
      next: "未來 30 分鐘計畫",
      links: "參考資訊",
    },
    phrases: {
      metadataOwner: "值班負責人",
      metadataRunbook: "處置手冊",
      metadataRegion: "區域",
      attrEnvironment: "環境",
      attrWindow: "維護視窗",
      attrRecovery: "恢復策略",
      attrImpact: "影響範圍",
      attrChanges: "屬性變更",
      changeFrom: "從",
      changeTo: "到",
      briefTitle: "管理層簡報",
      objectTitle: "物件更新",
      eventTitle: "事件更新",
      bodyImpact: "使用者端影響已受控，未發生硬中斷。",
      bodyRisk: "主要風險為處置延遲造成二次連鎖故障。",
      bodyAction: "責任人已確認執行，預計完成時間在 SLA 內。",
      bodyResolved: "恢復檢查通過，回滾方案維持就緒。",
      screenshotNote: "用於 App Store 多語系截圖的展示資料。",
    },
  },
};

const scenarioDefs = [
  {
    key: "ops",
    channelId: "ops-core",
    thingId: "thing_ops_cluster_sh1",
    thingCode: "OPS-SH1",
    events: ["latency", "packet", "disk", "tls", "policy"],
    location: "Datacenter A",
    owner: "SRE-01",
    imageTheme: "server-rack",
  },
  {
    key: "home",
    channelId: "home-automation",
    thingId: "thing_home_hub_cn2",
    thingCode: "HOME-CN2",
    events: ["hvac", "water", "entry", "power", "battery"],
    location: "Residential Block 7",
    owner: "HOME-OPS",
    imageTheme: "smart-home",
  },
  {
    key: "finance",
    channelId: "finance-ledger",
    thingId: "thing_finance_book_hk9",
    thingCode: "FIN-HK9",
    events: ["transfer", "fx", "cashflow", "invoice", "payroll"],
    location: "Ledger Cluster East",
    owner: "FIN-RISK",
    imageTheme: "finance-dashboard",
  },
  {
    key: "monitor",
    channelId: "event-monitoring",
    thingId: "thing_monitor_pipeline_sg3",
    thingCode: "MON-SG3",
    events: ["api", "crawler", "webhook", "cpu", "queue"],
    location: "Observability Hub",
    owner: "MON-TEAM",
    imageTheme: "monitoring-wall",
  },
  {
    key: "ai",
    channelId: "ai-agent-feedback",
    thingId: "thing_ai_agent_fleet_v2",
    thingCode: "AI-V2",
    events: ["tool", "token", "memory", "approval", "hallucination"],
    location: "Agent Runtime Pool",
    owner: "AI-OPS",
    imageTheme: "ai-control-room",
  },
];

const statusOrder = ["detected", "investigating", "resolved"];
const severityByStage = {
  detected: "critical",
  investigating: "high",
  resolved: "low",
};
const eventStateByStage = {
  detected: "active",
  investigating: "active",
  resolved: "closed",
};

function encodeMetadataString(object) {
  return JSON.stringify(object);
}

function markdownBody(localeCode, headline, scenarioLabel, stageLabel, imageUrl, bulletSeed) {
  const lang = copy[localeCode];
  return [
    `# ${headline}`,
    `> ${lang.sections.summary}: ${scenarioLabel} · ${stageLabel}`,
    "",
    `## ${lang.sections.signals}`,
    `- ${bulletSeed[0]}`,
    `- ${bulletSeed[1]}`,
    `- ${bulletSeed[2]}`,
    "",
    `## ${lang.sections.timeline}`,
    `1. T+0m: ${lang.phrases.bodyImpact}`,
    `2. T+8m: ${lang.phrases.bodyRisk}`,
    `3. T+16m: ${lang.phrases.bodyAction}`,
    `4. T+25m: ${lang.phrases.bodyResolved}`,
    "",
    `## ${lang.sections.next}`,
    "- [x] Fallback route confirmed",
    "- [x] Retry policy aligned",
    "- [ ] Incident retro document pending",
    "",
    `## ${lang.sections.links}`,
    `- ${lang.phrases.screenshotNote}`,
    `- ![context-image](${imageUrl})`,
  ].join("\n");
}

function imageUrl(theme, localeCode, scenarioKey, eventKey, stage) {
  const text = encodeURIComponent(`${localeCode.toUpperCase()} ${scenarioKey} ${eventKey} ${stage}`);
  const bg = {
    ops: "0E1A2B",
    home: "0B2E24",
    finance: "10221A",
    monitor: "1C122B",
    ai: "1F1A10",
  }[scenarioKey] ?? "1A1A1A";
  return `https://placehold.co/1280x720/${bg}/F4F7FF.png?text=${text}%0A${encodeURIComponent(theme)}`;
}

function thingImageUrls(localeCode, scenarioKey) {
  const cover = imageUrl("object-cover", localeCode, scenarioKey, "thing", "cover");
  const detail = imageUrl("object-detail", localeCode, scenarioKey, "thing", "detail");
  return [cover, detail];
}

function pushMessage(idCounter, messageId, title, body, channelId, receivedAtISO, payload) {
  const id = `00000000-0000-0000-0000-${String(idCounter).padStart(12, "0")}`;
  return {
    id,
    message_id: messageId,
    title,
    body,
    channel_id: channelId,
    is_read: false,
    received_at: receivedAtISO,
    raw_payload: payload,
    status: "normal",
  };
}

function makeFixture(localeCode) {
  const lang = copy[localeCode];
  const messages = [];
  let counter = 3200;
  const base = Date.parse("2026-05-08T05:00:00.000Z");
  let minuteOffset = 0;

  for (const [scenarioIndex, scenario] of scenarioDefs.entries()) {
    const scenarioLabel = lang.scenarios[scenario.key];
    const thingDisplayName = `${scenarioLabel} ${lang.channelWord} ${scenario.thingCode}`;

    const attrBase = {
      [lang.phrases.attrEnvironment]: scenarioLabel,
      [lang.phrases.attrWindow]: "02:00-04:00 UTC",
      [lang.phrases.attrRecovery]: lang.stages.investigating,
      [lang.phrases.attrImpact]: lang.phrases.bodyImpact,
    };

    for (let briefIdx = 1; briefIdx <= 3; briefIdx += 1) {
      const briefTitle = `${lang.phrases.briefTitle} · ${scenarioLabel} #${briefIdx}`;
      const briefImage = imageUrl(
        `${scenario.imageTheme}-brief`,
        localeCode,
        scenario.key,
        "brief",
        String(briefIdx)
      );
      const body = markdownBody(
        localeCode,
        briefTitle,
        scenarioLabel,
        lang.phrases.objectTitle,
        briefImage,
        [
          `${scenarioLabel} control plane remains available with degraded redundancy.`,
          `${thingDisplayName} health checks are still returning partial success.`,
          `${lang.phrases.bodyAction}`,
        ]
      );

      const payload = {
        entity_type: "thing",
        entity_id: scenario.thingId,
        thing_id: scenario.thingId,
        projection_destination: "thing_head",
        title: `${lang.phrases.objectTitle} · ${thingDisplayName}`,
        description: `${scenarioLabel} ${lang.phrases.objectTitle} ${briefIdx}`,
        status: lang.statuses.investigating,
        message: `${lang.phrases.objectTitle}: ${lang.phrases.bodyImpact}`,
        severity: "medium",
        tags: [scenarioLabel, lang.phrases.objectTitle, lang.languageName],
        location: {
          type: lang.phrases.metadataRegion,
          value: scenario.location,
        },
        external_ids: {
          asset: scenario.thingCode,
          owner: scenario.owner,
        },
        primary_image: thingImageUrls(localeCode, scenario.key)[0],
        images: thingImageUrls(localeCode, scenario.key),
        attrs: {
          ...attrBase,
          note: `${lang.phrases.objectTitle} ${briefIdx}`,
        },
        attr_changes: [
          {
            field: lang.phrases.attrRecovery,
            [lang.phrases.changeFrom]: lang.stages.detected,
            [lang.phrases.changeTo]: lang.stages.investigating,
            changed_at: Math.floor((base - minuteOffset * 60_000) / 1000),
          },
          {
            field: lang.phrases.attrImpact,
            [lang.phrases.changeFrom]: "partial",
            [lang.phrases.changeTo]: "controlled",
            changed_at: Math.floor((base - (minuteOffset + 1) * 60_000) / 1000),
          },
        ],
        metadata: encodeMetadataString({
          [lang.phrases.metadataOwner]: scenario.owner,
          [lang.phrases.metadataRunbook]: `RB-${scenario.thingCode}`,
          [lang.phrases.metadataRegion]: scenario.location,
          locale: localeCode,
        }),
      };

      const msgId = `msg_${scenario.key}_brief_${String(briefIdx).padStart(3, "0")}`;
      const receivedAt = new Date(base - minuteOffset * 60_000).toISOString();
      messages.push(pushMessage(counter, msgId, briefTitle, body, scenario.channelId, receivedAt, payload));
      counter += 1;
      minuteOffset += 1;
    }

    for (const [eventIndex, eventKey] of scenario.events.entries()) {
      const eventId = `evt_${scenario.key}_${eventKey}_${String(eventIndex + 1).padStart(3, "0")}`;
      const eventName = lang.eventNames[eventKey];

      for (const [stageIndex, stage] of statusOrder.entries()) {
        const stageText = lang.statuses[stage];
        const stageDetail = lang.stages[stage];
        const title = `${eventName} · ${stageText}`;
        const eventImage = imageUrl(
          scenario.imageTheme,
          localeCode,
          scenario.key,
          eventKey,
          stage
        );
        const body = markdownBody(
          localeCode,
          title,
          scenarioLabel,
          stageText,
          eventImage,
          [
            `${eventName}: ${stageDetail}`,
            `${lang.phrases.bodyRisk}`,
            `${lang.phrases.bodyResolved}`,
          ]
        );

        const payload = {
          entity_type: "event",
          entity_id: eventId,
          event_id: eventId,
          thing_id: scenario.thingId,
          projection_destination: "event_head",
          event_state: eventStateByStage[stage],
          event_time: Math.floor((base - minuteOffset * 60_000) / 1000),
          observed_at: Math.floor((base - minuteOffset * 60_000) / 1000),
          title: eventName,
          description: `${eventName} · ${stageDetail}`,
          status: stageText,
          message: `${lang.phrases.eventTitle}: ${lang.phrases.bodyImpact}`,
          severity: severityByStage[stage],
          tags: [scenarioLabel, eventName, lang.languageName],
          location: {
            type: lang.phrases.metadataRegion,
            value: scenario.location,
          },
          external_ids: {
            thing_code: scenario.thingCode,
            owner: scenario.owner,
            stage,
          },
          images: [
            eventImage,
            imageUrl(`${scenario.imageTheme}-detail`, localeCode, scenario.key, eventKey, `${stage}-detail`),
          ],
          attrs: {
            ...attrBase,
            stage: stageDetail,
            [lang.phrases.attrChanges]: `${eventName} ${stageText}`,
          },
          metadata: encodeMetadataString({
            [lang.phrases.metadataOwner]: scenario.owner,
            [lang.phrases.metadataRunbook]: `EVT-${scenario.thingCode}-${eventIndex + 1}`,
            [lang.phrases.metadataRegion]: scenario.location,
            stage: stageText,
            locale: localeCode,
          }),
        };

        const msgId = `msg_${scenario.key}_${eventKey}_${eventIndex + 1}_${stageIndex + 1}`;
        const receivedAt = new Date(base - minuteOffset * 60_000).toISOString();
        messages.push(pushMessage(counter, msgId, title, body, scenario.channelId, receivedAt, payload));
        counter += 1;
        minuteOffset += 1;
      }
    }

    const summaryTitle = `${scenarioLabel} · ${lang.phrases.briefTitle} ${scenarioIndex + 1}`;
    const summaryImage = imageUrl("executive-summary", localeCode, scenario.key, "summary", "final");
    const summaryBody = markdownBody(
      localeCode,
      summaryTitle,
      scenarioLabel,
      lang.phrases.briefTitle,
      summaryImage,
      [
        `${scenarioLabel} trend: 5 events tracked with full lifecycle records.`,
        `${scenarioLabel} object contains 3 detailed narrative updates.`,
        `${lang.phrases.bodyResolved}`,
      ]
    );

    messages.push(
      pushMessage(
        counter,
        `msg_${scenario.key}_exec_${String(scenarioIndex + 1).padStart(3, "0")}`,
        summaryTitle,
        summaryBody,
        "executive-brief",
        new Date(base - minuteOffset * 60_000).toISOString(),
        {
          entity_type: "thing",
          entity_id: scenario.thingId,
          thing_id: scenario.thingId,
          projection_destination: "thing_head",
          title: summaryTitle,
          description: `${lang.phrases.briefTitle} · ${scenarioLabel}`,
          status: lang.statuses.resolved,
          message: lang.phrases.bodyResolved,
          severity: "low",
          tags: [lang.phrases.briefTitle, scenarioLabel, lang.languageName],
          images: [summaryImage],
          attrs: {
            scenario: scenarioLabel,
            locale: localeCode,
            score: "A",
          },
          metadata: encodeMetadataString({
            owner: scenario.owner,
            locale: localeCode,
            object: scenario.thingCode,
          }),
        }
      )
    );
    counter += 1;
    minuteOffset += 1;
  }

  messages.sort((a, b) => Date.parse(b.received_at) - Date.parse(a.received_at));

  const channelSubscriptions = [
    {
      channel_id: "ops-core",
      display_name: `${lang.scenarios.ops}${lang.channelWord}`,
      password: "pw_ops_core",
      last_synced_at: "2026-05-08T04:20:00.000Z",
      updated_at: "2026-05-08T04:20:00.000Z",
    },
    {
      channel_id: "home-automation",
      display_name: `${lang.scenarios.home}${lang.channelWord}`,
      password: "pw_home_automation",
      last_synced_at: "2026-05-08T04:21:00.000Z",
      updated_at: "2026-05-08T04:21:00.000Z",
    },
    {
      channel_id: "finance-ledger",
      display_name: `${lang.scenarios.finance}${lang.channelWord}`,
      password: "pw_finance_ledger",
      last_synced_at: "2026-05-08T04:22:00.000Z",
      updated_at: "2026-05-08T04:22:00.000Z",
    },
    {
      channel_id: "event-monitoring",
      display_name: `${lang.scenarios.monitor}${lang.channelWord}`,
      password: "pw_event_monitoring",
      last_synced_at: "2026-05-08T04:23:00.000Z",
      updated_at: "2026-05-08T04:23:00.000Z",
    },
    {
      channel_id: "ai-agent-feedback",
      display_name: `${lang.scenarios.ai}${lang.channelWord}`,
      password: "pw_ai_agent_feedback",
      last_synced_at: "2026-05-08T04:24:00.000Z",
      updated_at: "2026-05-08T04:24:00.000Z",
    },
    {
      channel_id: "executive-brief",
      display_name: `${lang.phrases.briefTitle}${lang.channelWord}`,
      password: "pw_executive_brief",
      last_synced_at: "2026-05-08T04:25:00.000Z",
      updated_at: "2026-05-08T04:25:00.000Z",
    },
    {
      channel_id: "incident-command",
      display_name: `Incident Command ${lang.channelWord}`,
      password: "pw_incident_command",
      last_synced_at: "2026-05-08T04:26:00.000Z",
      updated_at: "2026-05-08T04:26:00.000Z",
    },
    {
      channel_id: "customer-trust",
      display_name: `Customer Trust ${lang.channelWord}`,
      password: "pw_customer_trust",
      last_synced_at: "2026-05-08T04:27:00.000Z",
      updated_at: "2026-05-08T04:27:00.000Z",
    },
  ];

  return { messages, channel_subscriptions: channelSubscriptions };
}

function writeFixture(localeCode, fixture) {
  const file = path.join(fixtureDir, `localization-showcase.${localeCode}.json`);
  fs.writeFileSync(file, `${JSON.stringify(fixture, null, 2)}\n`, "utf8");
}

fs.mkdirSync(fixtureDir, { recursive: true });
for (const locale of locales) {
  const fixture = makeFixture(locale.code);
  writeFixture(locale.code, fixture);
  if (locale.code === "zh-CN") {
    const baseFile = path.join(fixtureDir, "localization-showcase.json");
    fs.writeFileSync(baseFile, `${JSON.stringify(fixture, null, 2)}\n`, "utf8");
  }
}

console.log(`Generated ${locales.length} localized fixtures in ${fixtureDir}`);
