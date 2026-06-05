import Foundation
import SwiftUI

enum Lang: String, CaseIterable, Identifiable {
    case en, ru, es
    var id: String { rawValue }
    var display: String {
        switch self {
        case .en: return "English"
        case .ru: return "Русский"
        case .es: return "Español"
        }
    }
    var flag: String {
        switch self { case .en: return "🇬🇧"; case .ru: return "🇷🇺"; case .es: return "🇪🇸" }
    }
    var index: Int { switch self { case .en: return 0; case .ru: return 1; case .es: return 2 } }
}

/// App brand names (not localized — constant across languages).
enum Brand {
    static let long = "Office Sentinel Disk Manager"
    static let short = "OS Disk Manager"
}

@MainActor
final class Loc: ObservableObject {
    static let shared = Loc()

    @Published var lang: Lang {
        didSet { UserDefaults.standard.set(lang.rawValue, forKey: "appLanguage") }
    }

    init() {
        if let s = UserDefaults.standard.string(forKey: "appLanguage"), let l = Lang(rawValue: s) {
            // User has explicitly chosen a language before — honour it.
            lang = l
        } else {
            // First launch: try to match the system's preferred languages.
            // If none of our supported (en/ru/es) appear in the list — fall back to English.
            lang = Self.detectSystemLanguage()
            // Persist so we don't re-detect on every launch.
            UserDefaults.standard.set(lang.rawValue, forKey: "appLanguage")
        }
    }

    /// Picks the highest-priority language from the user's system preferences that we
    /// actually support. Returns .en when no match is found.
    static func detectSystemLanguage() -> Lang {
        for preferred in Locale.preferredLanguages {
            let code = String(preferred.lowercased().prefix(2))
            if let lang = Lang(rawValue: code) { return lang }
        }
        return .en
    }

    func t(_ key: String) -> String {
        guard let row = Self.table[key] else { return key }
        let i = lang.index
        return i < row.count ? row[i] : row[0]
    }
    /// Format with args, e.g. t("card.partitions.count", 3)
    func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    // [key: [en, ru, es]]
    static let table: [String: [String]] = [
        // tabs
        "tab.overview": ["Overview", "Обзор", "Resumen"],
        "tab.wipe": ["Erase + Test", "Стирание + тест", "Borrado + Test"],
        "tab.scan": ["Surface Scan", "Скан поверхности", "Escaneo"],
        "tab.partitions": ["Partitions", "Разделы", "Particiones"],
        "tab.history": ["History", "История", "Historial"],
        // history
        "history.disksList": ["Disks ever connected", "Подключавшиеся диски", "Discos conectados"],
        "history.noDisks": ["No disks recorded yet. Plug in a drive — a snapshot is taken automatically.", "Пока ничего не записано. Подключи диск — снимок создастся автоматически.", "Aún no hay nada. Conecta un disco — se tomará una captura automáticamente."],
        "history.timeline": ["Snapshot timeline", "Хронология снимков", "Cronología de capturas"],
        "history.compare": ["Compare", "Сравнить", "Comparar"],
        "history.compareHint": ["Select 2 snapshots to compare", "Выбери 2 снимка для сравнения", "Selecciona 2 capturas para comparar"],
        "history.kind.snapshot": ["Dashboard snapshot", "Снимок дашборда", "Captura del panel"],
        "history.kind.wipe": ["After wipe", "После стирания", "Tras borrado"],
        "history.chartWear": ["Wear used (%)", "Износ (%)", "Desgaste (%)"],
        "history.chartTemp": ["Temperature (°C)", "Температура (°C)", "Temperatura (°C)"],
        "history.chartDefects": ["Defects (count)", "Дефекты (шт.)", "Defectos"],
        "history.chartPOH": ["Operating time (h)", "Время работы (ч)", "Tiempo de uso (h)"],
        "history.lastSeen": ["Last seen", "Последний раз", "Última vez"],
        "history.snapshots": ["Snapshots: %d", "Снимков: %d", "Capturas: %d"],
        "history.detail": ["Snapshot detail", "Подробности снимка", "Detalle de la captura"],
        "history.openReport": ["Open full report", "Открыть полный отчёт", "Abrir informe completo"],
        "compare.title": ["Compare snapshots", "Сравнение снимков", "Comparar capturas"],
        "compare.attribute": ["Attribute", "Показатель", "Atributo"],
        "compare.before": ["Earlier", "Раньше", "Antes"],
        "compare.after": ["Later", "Позже", "Después"],
        "compare.delta": ["Δ", "Δ", "Δ"],
        "compare.changedOnly": ["Show only changed", "Только изменённые", "Solo cambios"],
        "compare.close": ["Close", "Закрыть", "Cerrar"],
        "compare.summary": ["Health changes overview", "Сводка изменений здоровья", "Resumen de cambios"],
        "part.resizeSizeRequired": ["Size is required — enter a value like 200G, 50%, or R (recommended).",
                                    "Размер обязателен — укажите значение вроде 200G, 50% или R (рекомендуемое).",
                                    "El tamaño es obligatorio — escriba un valor como 200G, 50% o R (recomendado)."],
        "common.openLogs": ["Open logs", "Открыть логи", "Abrir registros"],
        // wipe detail card (history)
        "wipe.detail.title": ["Erase + verify details", "Детали стирания и проверки", "Detalles del borrado y verificación"],
        "wipe.detail.mode": ["Mode", "Режим", "Modo"],
        "wipe.detail.erase": ["Erase", "Стирание", "Borrado"],
        "wipe.detail.verify": ["Verify", "Проверка", "Verificación"],
        "wipe.detail.elapsed": ["Elapsed", "Длительность", "Tiempo"],
        "wipe.detail.min": ["min", "мин", "mín"],
        "wipe.detail.avg": ["avg", "сред", "med"],
        "wipe.detail.max": ["max", "макс", "máx"],
        "wipe.detail.longTest": ["SMART long self-test", "Длительный самотест SMART", "Autotest extendido SMART"],
        // scan detail card (history)
        "scan.detail.title": ["Surface scan results", "Результаты сканирования поверхности", "Resultados del escaneo de superficie"],
        "scan.detail.threshold": ["Threshold", "Порог", "Umbral"],
        "scan.detail.blocks": ["Blocks scanned", "Блоков просканировано", "Bloques escaneados"],
        "scan.detail.avgMs": ["avg latency", "средняя задержка", "latencia media"],
        "scan.detail.maxMs": ["max latency", "макс. задержка", "latencia máx."],
        "scan.detail.bad": ["Bad sectors", "Плохих секторов", "Sectores defectuosos"],
        "scan.detail.bandsTitle": ["Block distribution", "Распределение блоков", "Distribución de bloques"],
        "history.kind.scan": ["Surface scan", "Скан поверхности", "Escaneo"],
        "history.health": ["Health", "Здоровье", "Salud"],
        "history.deltaSince": ["vs %@", "относ. %@", "vs %@"],
        "history.now": ["now", "сейчас", "ahora"],
        "history.first": ["first", "первый", "primero"],
        "trim.label": ["TRIM", "TRIM", "TRIM"],
        "trim.yes": ["yes", "да", "sí"],
        "trim.no": ["no", "нет", "no"],
        "trim.nodata": ["no data", "нет данных", "sin datos"],
        "trim.level.DZAT": ["DZAT — deterministic, zero after TRIM (strongest)",
                             "DZAT — детерминированно, после TRIM возвращает нули (самый сильный)",
                             "DZAT — determinista, ceros tras TRIM (más fuerte)"],
        "trim.level.DRAT": ["DRAT — deterministic read after TRIM",
                             "DRAT — детерминированное чтение после TRIM",
                             "DRAT — lectura determinista tras TRIM"],
        "trim.level.basic": ["Basic TRIM (no determinism guarantee)",
                              "Базовый TRIM (без гарантии детерминизма)",
                              "TRIM básico (sin garantía determinista)"],
        "tier.label": ["Class", "Класс", "Clase"],
        "tier.enterprise": ["Enterprise / Server", "Серверный / Enterprise", "Empresarial"],
        "tier.consumer": ["Consumer", "Бытовой", "De consumo"],
        "tier.unknown": ["Cannot determine", "Не определено", "No determinado"],
        "tier.help.enterprise": ["Datacenter / professional drive — high endurance, power-loss protection.",
                                  "Профессиональный / датацентровый диск — высокий ресурс, защита от потери питания.",
                                  "Disco profesional/centro de datos — alta resistencia, protección contra cortes."],
        "tier.help.consumer": ["Consumer / OEM client drive — typical desktop/laptop class.",
                                "Бытовой / OEM-клиентский диск — обычный класс для ПК/ноутбука.",
                                "Disco de consumo / cliente OEM — clase típica de PC/portátil."],
        "tier.help.unknown": ["No strong signal — model, interface or capacity didn't match known patterns.",
                               "Нет уверенного признака — модель, интерфейс или ёмкость не дали явного указания.",
                               "Sin señal clara — modelo, interfaz o capacidad no coinciden."],
        "discard.label": ["Discard", "Discard", "Discard"],
        "discard.help": ["Space-reclaim command. Name depends on interface: TRIM (SATA), Deallocate (NVMe), UNMAP (SAS).",
                          "Команда освобождения места. На SATA — TRIM, на NVMe — Deallocate, на SAS — UNMAP.",
                          "Comando de liberación de espacio. Según interfaz: TRIM (SATA), Deallocate (NVMe), UNMAP (SAS)."],
        "sanitize.label": ["Sanitize", "Sanitize", "Sanitize"],
        "sanitize.none": ["no data", "нет данных", "sin datos"],
        "sanitize.help": ["Secure-erase commands beyond TRIM: ATA Security Erase, ATA Sanitize, NVMe Format/Sanitize. Used to destroy data fully (not just mark blocks as free).",
                           "Команды безопасного стирания (не путать с TRIM): ATA Security Erase, ATA Sanitize, NVMe Format/Sanitize. Полностью уничтожают данные, а не просто отмечают блоки свободными.",
                           "Comandos de borrado seguro (no son TRIM): ATA Security Erase, ATA Sanitize, NVMe Format/Sanitize. Destruyen los datos por completo."],
        "cache.label": ["DRAM cache", "DRAM-кэш", "Caché DRAM"],
        "cache.yes": ["yes", "да", "sí"],
        "cache.no": ["no (DRAM-less)", "нет (DRAM-less)", "no (sin DRAM)"],
        "cache.unknown": ["unknown", "не определено", "desconocido"],
        "cache.help": ["DRAM cache buffer on the drive. Improves sustained write speed and reduces wear. Absent on budget SSDs (\"DRAM-less\"). Detected by model — over USB the bridge usually hides this info.",
                        "Наличие DRAM-буфера на самом диске. Ускоряет долгую запись и снижает износ. Отсутствует у бюджетных SSD (\"DRAM-less\"). Определяется по модели — USB-мост обычно скрывает этот параметр.",
                        "Búfer DRAM en la propia unidad. Mejora la escritura sostenida y reduce el desgaste. Ausente en SSD económicos (\"DRAM-less\"). Detectado por modelo — USB suele ocultarlo."],
        "nand.label": ["NAND", "NAND", "NAND"],
        "nand.unknown": ["unknown", "не определено", "desconocido"],
        "nand.help.slc": ["SLC — 1 bit/cell, ~100k P/E cycles, highest endurance. Rare in consumer.",
                          "SLC — 1 бит/ячейка, ~100k P/E циклов, максимальный ресурс. Редко в бытовых.",
                          "SLC — 1 bit/celda, ~100k ciclos P/E, máxima resistencia. Raro en consumo."],
        "nand.help.mlc": ["MLC — 2 bits/cell, ~3k-10k P/E cycles, high endurance.",
                          "MLC — 2 бита/ячейка, ~3k-10k P/E циклов, высокий ресурс.",
                          "MLC — 2 bits/celda, ~3k-10k ciclos P/E, alta resistencia."],
        "nand.help.tlc": ["TLC — 3 bits/cell, ~1k-3k P/E cycles, the modern mainstream.",
                          "TLC — 3 бита/ячейка, ~1k-3k P/E циклов, современный mainstream.",
                          "TLC — 3 bits/celda, ~1k-3k ciclos P/E, mainstream actual."],
        "nand.help.qlc": ["QLC — 4 bits/cell, ~100-1k P/E cycles, lowest endurance — budget/archival.",
                          "QLC — 4 бита/ячейка, ~100-1k P/E циклов, низкий ресурс — бюджет/архив.",
                          "QLC — 4 bits/celda, ~100-1k ciclos P/E, baja resistencia — económico/archivo."],
        "plp.label": ["PLP", "PLP", "PLP"],
        "plp.yes": ["yes", "да", "sí"],
        "plp.no": ["no", "нет", "no"],
        "plp.unknown": ["unknown", "не определено", "desconocido"],
        "plp.help": ["Power-Loss Protection — on-disk capacitors that finish in-flight writes during a sudden power loss. Standard on enterprise drives, absent on most consumer.",
                      "Power-Loss Protection — конденсаторы на диске, которые дописывают данные при внезапной потере питания. Стандарт для серверных, отсутствует у большинства бытовых.",
                      "Power-Loss Protection — condensadores en el disco que terminan las escrituras al cortarse la energía. Estándar en empresarial, ausente en la mayoría de consumo."],
        "tbw.title": ["Endurance", "Ресурс записи", "Resistencia"],
        "tbw.used": ["used", "израсходовано", "usado"],
        "tbw.of": ["of", "из", "de"],
        "tbw.rated": ["rated", "ресурс", "nominal"],
        "tbw.unknown": ["No endurance data", "Нет данных о ресурсе", "Sin datos de resistencia"],
        "tbw.help": ["TBW = Terabytes Written. Spec value × disk size. Combined with current wear percentage shows how much of the rated lifetime has been consumed.",
                       "TBW = терабайт записи. Спецификация × ёмкость. Вместе с текущим % износа показывает сколько ресурса израсходовано.",
                       "TBW = terabytes escritos. Especificación × tamaño. Junto con el % de desgaste actual indica cuánta vida útil se ha consumido."],
        "db.refresh": ["Refresh DB", "Обновить базу", "Actualizar BD"],
        "db.updated": ["Database updated", "База обновлена", "Base actualizada"],
        "db.upToDate": ["Database is up to date", "База актуальна", "Base actualizada"],
        "db.failed": ["Update failed (offline?)", "Не удалось обновить (нет сети?)", "Error de actualización (¿sin red?)"],
        "source.OurDB": ["Source: model database", "Источник: база моделей", "Fuente: base de modelos"],
        "source.smartctl": ["Source: smartctl drivedb fallback (limited)", "Источник: drivedb smartctl (ограничено)", "Fuente: drivedb de smartctl (limitado)"],
        "source.none": ["No metadata source matched — DRAM/NAND/PLP shown as \"no data\".",
                          "Ни одна база не опознала модель — DRAM/NAND/PLP показываются как «нет данных».",
                          "Ninguna fuente identificó el modelo — DRAM/NAND/PLP se muestran como «sin datos»."],
        "history.staticSpecs": ["Static specs", "Характеристики", "Especificaciones"],
        "history.currentState": ["Current state", "Текущее состояние", "Estado actual"],
        "source.label": ["Source", "Источник", "Fuente"],
        "os.unsupported.title": ["Unsupported macOS version",
                                   "Несовместимая версия macOS",
                                   "Versión de macOS no compatible"],
        "os.unsupported.body": ["OS Disk Manager requires macOS 14 (Sonoma) or later. Your current version: %@. Please update macOS to continue.",
                                  "OS Disk Manager требует macOS 14 (Sonoma) или новее. Ваша текущая версия: %@. Обновите macOS для продолжения работы.",
                                  "OS Disk Manager requiere macOS 14 (Sonoma) o posterior. Su versión actual: %@. Actualice macOS para continuar."],
        "os.unsupported.button": ["Quit", "Выйти", "Salir"],
        // Capability reasons (why an action is disabled)
        "cap.service": ["Service partition (EFI / Recovery) — protected.",
                         "Служебный раздел (EFI / Recovery) — защищён.",
                         "Partición de servicio (EFI / Recovery) — protegida."],
        "cap.ntfsNoFormat": ["macOS can't format NTFS — do it from Windows. To get rid of it on macOS, use «Repartition disk» (wipes the whole disk).",
                              "macOS не умеет форматировать NTFS — сделай это из Windows. Чтобы убрать его на macOS — «Переразметить диск» (стирает весь диск).",
                              "macOS no puede formatear NTFS — hazlo desde Windows. Para eliminarlo en macOS, usa «Reparticionar disco» (borra todo el disco)."],
        "cap.ntfsResize": ["macOS can't resize NTFS. Resize from Windows or a Linux live USB. Or wipe everything via «Repartition disk».",
                            "macOS не умеет менять размер NTFS. Сделай это из Windows или с Linux Live USB. Или сотри всё через «Переразметить диск».",
                            "macOS no puede redimensionar NTFS. Usa Windows o un Linux Live USB. O borra todo con «Reparticionar disco»."],
        "cap.exfatResize": ["ExFAT can't be resized on macOS — recreate via Repartition.",
                             "ExFAT нельзя изменить в размере на macOS — пересоздай через «Переразметить диск».",
                             "ExFAT no se puede redimensionar en macOS — recrear con «Reparticionar disco»."],
        "cap.fatResize": ["FAT32 can't be resized on macOS — recreate via Repartition.",
                           "FAT32 нельзя изменить в размере на macOS — пересоздай через «Переразметить диск».",
                           "FAT32 no se puede redimensionar en macOS — recrear con «Reparticionar disco»."],
        "cap.extResize": ["ext resize isn't enabled here (no safe partition-table sync).",
                           "Изменение размера ext в этой программе отключено (нет безопасной правки таблицы).",
                           "Cambiar tamaño de ext está deshabilitado aquí."],
        "cap.unknownFS": ["Unknown filesystem — only Repartition is safe.",
                           "Неизвестная файловая система — безопасна только переразметка.",
                           "Sistema de archivos desconocido — solo es seguro reparticionar."],
        "cap.apfsContainer": ["APFS volume — resize the container itself, not the volume.",
                               "Том APFS — меняй размер контейнера, а не самого тома.",
                               "Volumen APFS — redimensiona el contenedor, no el volumen."],
        "cap.prevNotResizable": ["macOS can only delete a partition by merging it into a resizable neighbor (APFS/HFS+). To remove this one — use «Repartition disk» (destroys all data on the disk).",
                                  "macOS умеет удалять раздел только сливая его с resize-уемым соседом (APFS/HFS+). Чтобы удалить этот — используй «Переразметить диск» (уничтожит все данные на диске).",
                                  "macOS solo elimina particiones fusionándolas con un vecino redimensionable (APFS/HFS+). Para borrar esta — usa «Reparticionar disco» (destruye todos los datos del disco)."],
        "cap.firstPartition": ["The first partition can't be deleted into a previous one. To remove it — use «Repartition disk» (destroys all data on the disk).",
                                "Первый раздел нельзя удалить в предыдущий. Чтобы его убрать — используй «Переразметить диск» (уничтожит все данные на диске).",
                                "La primera partición no puede eliminarse así. Para borrarla — usa «Reparticionar disco» (destruye todos los datos del disco)."],
        "cap.statusHint": ["Hover a disabled button for the reason.",
                            "Наведи на неактивную кнопку — увидишь причину.",
                            "Pasa el cursor sobre un botón inactivo para ver el motivo."],
        // common
        "common.disk": ["Disk:", "Диск:", "Disco:"],
        "common.cancel": ["Cancel", "Отмена", "Cancelar"],
        "common.retry": ["Retry", "Повторить", "Reintentar"],
        "common.scheme": ["Scheme", "Схема", "Esquema"],
        // dashboard
        "dash.save": ["Save report", "Сохранить отчёт", "Guardar informe"],
        "dash.nodata": ["No data", "Нет данных", "Sin datos"],
        "dash.reading": ["Reading SMART…", "Чтение SMART…", "Leyendo SMART…"],
        "dash.wait": ["Please wait…", "Подождите…", "Espere…"],
        "dash.selectDisk": ["Select a disk", "Выберите диск", "Seleccione un disco"],
        "dash.openFDA": ["Open Full Disk Access", "Открыть Full Disk Access", "Abrir Acceso Total al Disco"],
        "dash.fdaHint": [
            "Couldn't read SMART. Full Disk Access is likely required for OS Disk Manager (System Settings → Privacy & Security → Full Disk Access), then relaunch.",
            "Не удалось прочитать SMART. Вероятно, нужен Full Disk Access для OS Disk Manager (System Settings → Privacy & Security → Full Disk Access), затем перезапуск.",
            "No se pudo leer SMART. Probablemente se requiere Acceso Total al Disco para OS Disk Manager (Ajustes → Privacidad y seguridad → Acceso total al disco), luego reiniciar."],
        "gauge.life": ["Life", "Ресурс", "Vida"],
        "gauge.life.sub": ["remaining", "осталось", "restante"],
        "gauge.temp": ["Temp.", "Темп.", "Temp."],
        "gauge.temp.now": ["now", "сейчас", "ahora"],
        "gauge.temp.max": ["max %d°", "max %d°", "máx %d°"],
        "gauge.poweron": ["Operating time", "Время работы", "Tiempo de uso"],
        "gauge.poweron.sub": ["hours", "часов", "horas"],
        "card.partitions": ["Partitions", "Разделы", "Particiones"],
        "card.partitions.count": ["%d total", "всего %d", "%d en total"],
        "stat.cycles": ["Power-ups", "Включения", "Encendidos"],
        "stat.poweron": ["Operating time", "Время работы", "Tiempo de uso"],
        "stat.wear": ["Memory wear", "Износ памяти", "Desgaste de memoria"],
        "stat.defects": ["Defects", "Дефекты", "Defectos"],
        "dash.partmap": ["Partition map", "Карта разделов", "Mapa de particiones"],
        "dash.smart": ["Health attributes", "Показатели состояния", "Atributos de estado"],
        "id.sn": ["Serial", "Серийный №", "N.º de serie"],
        "id.fw": ["Firmware", "Прошивка", "Firmware"],
        "smart.col.attr": ["Attribute", "Показатель", "Atributo"],
        "smart.col.value": ["Value", "Значение", "Valor"],
        "smart.col.worst": ["Worst", "Худшее", "Peor"],
        "smart.col.thresh": ["Threshold", "Порог", "Umbral"],
        "smart.col.raw": ["Data", "Данные", "Datos"],
        "health.passed": ["PASSED", "PASSED", "OK"],
        "health.failed": ["FAILED", "FAILED", "FALLO"],
        "common.empty": ["empty", "пусто", "vacío"],
        "common.free": ["free", "свободно", "libre"],
        "common.noname": ["(no name)", "(без имени)", "(sin nombre)"],
        // wipe
        "wipe.subtitle": ["Erase + disk health check", "Стирание + проверка состояния диска", "Borrado + comprobación del disco"],
        "wipe.mode": ["Mode:", "Режим:", "Modo:"],
        "mode.full": ["Full erase with verification", "Полное стирание с проверкой", "Borrado completo con verificación"],
        "mode.quick": ["Quick erase", "Быстрое стирание", "Borrado rápido"],
        "toggle.verify": ["Read-back check", "Проверка чтением", "Verificación por lectura"],
        "toggle.smartlong": ["Extended self-test", "Длительный самотест", "Autotest extendido"],
        "toggle.eject": ["Eject when done", "Извлечь по окончании", "Expulsar al terminar"],
        "wipe.start": ["Start erase", "Запустить стирание", "Iniciar borrado"],
        "wipe.cancel": ["Abort", "Прервать", "Abortar"],
        "wipe.warning": ["All data on the disk will be destroyed permanently.", "Все данные на диске будут уничтожены безвозвратно.", "Todos los datos del disco se destruirán permanentemente."],
        "wipe.phasesAppear": ["Steps will appear after start.", "Этапы появятся после запуска.", "Los pasos aparecerán al iniciar."],
        "log": ["Log", "Журнал", "Registro"],
        "speed.inst": ["instant", "мгновенная", "instant."],
        "speed.avg": ["average", "средняя", "media"],
        // phases
        "phase.smart_pre": ["Health check (before)", "Проверка состояния (до)", "Comprobación (antes)"],
        "phase.unmount": ["Unmount", "Отключение тома", "Desmontar"],
        "phase.erase_full": ["Full erase", "Полное стирание", "Borrado completo"],
        "phase.erase_quick": ["Quick erase", "Быстрое стирание", "Borrado rápido"],
        "phase.verify": ["Read verification", "Проверка чтением", "Verificación de lectura"],
        "phase.smart_long": ["Extended self-test", "Длительный самотест", "Autotest extendido"],
        "phase.finalize": ["Empty GPT", "Пустая GPT", "GPT vacía"],
        "phase.report": ["Report", "Отчёт", "Informe"],
        "phase.eject": ["Eject", "Извлечение", "Expulsión"],
        // scan
        "scan.title": ["Surface scan", "Посекторное сканирование", "Escaneo de superficie"],
        "scan.mode": ["Mode:", "Режим:", "Modo:"],
        "mode.read": ["Reading", "Чтение", "Lectura"],
        "mode.verify": ["Verification", "Проверка", "Verificación"],
        "scan.threshold": ["Threshold:", "Порог:", "Umbral:"],
        "scan.thresholdHint": ["blocks slower than the threshold are marked red", "блоки медленнее порога помечаются красным", "los bloques más lentos que el umbral se marcan en rojo"],
        "scan.start": ["Scan", "Сканировать", "Escanear"],
        "scan.stop": ["Stop", "Остановить", "Detener"],
        "scan.progress": ["progress", "прогресс", "progreso"],
        "scan.inst": ["instant", "мгновенная", "instantánea"],
        "scan.avg": ["average", "средняя", "media"],
        "scan.maxlat": ["max latency", "наибольшая задержка", "latencia máxima"],
        "scan.surfacemap": ["Surface map", "Карта поверхности", "Mapa de superficie"],
        "scan.bands": ["Latency bands", "Полосы задержки", "Bandas de latencia"],
        "band.0": ["under 5 ms", "менее 5 мс", "menos de 5 ms"],
        "band.1": ["5 to 20 ms", "от 5 до 20 мс", "de 5 a 20 ms"],
        "band.2": ["20 to 50 ms", "от 20 до 50 мс", "de 20 a 50 ms"],
        "band.3": ["50 to 150 ms", "от 50 до 150 мс", "de 50 a 150 ms"],
        "band.4": ["up to threshold", "до порога", "hasta el umbral"],
        "band.5": ["slower than threshold", "медленнее порога", "más lento que el umbral"],
        "band.6": ["read error", "ошибка чтения", "error de lectura"],
        // partitions
        "part.title": ["Partition management", "Управление разделами", "Gestión de particiones"],
        "part.repartition": ["Repartition disk", "Переразметить диск", "Reparticionar disco"],
        "part.format": ["Format", "Форматировать", "Formatear"],
        "part.resize": ["Resize", "Размер", "Redimensionar"],
        "part.add": ["Add", "Добавить", "Añadir"],
        "part.delete": ["Delete", "Удалить", "Eliminar"],
        "part.repartTitle": ["Repartition entire disk", "Переразметить весь диск", "Reparticionar todo el disco"],
        "part.repartWarn": ["All data on the disk will be destroyed.", "Все данные на диске будут уничтожены.", "Todos los datos del disco se destruirán."],
        "part.addPartition": ["Add partition", "Добавить раздел", "Añadir partición"],
        "part.name": ["Name", "Имя", "Nombre"],
        "part.size": ["Size (empty=rest, 50G, 50%)", "Размер (пусто=остаток, 50G, 50%)", "Tamaño (vacío=resto, 50G, 50%)"],
        "part.fs": ["Filesystem", "Файловая система", "Sistema de archivos"],
        "part.volName": ["Volume name", "Имя тома", "Nombre del volumen"],
        "part.formatTitle": ["Format %@", "Форматировать %@", "Formatear %@"],
        "part.eraseWarn": ["This volume's data will be erased.", "Данные этого тома будут стёрты.", "Los datos de este volumen se borrarán."],
        "part.current": ["Current: %@", "Текущее: %@", "Actual: %@"],
        "part.resizeTitle": ["Resize %@", "Изменить размер %@", "Redimensionar %@"],
        "part.now": ["Now: %@", "Сейчас: %@", "Ahora: %@"],
        "part.newSize": ["New size (e.g. 200G, or 100% = all)", "Новый размер (напр. 200G, или 100% — занять всё)", "Nuevo tamaño (p.ej. 200G, o 100% = todo)"],
        "part.makeNew": ["Create a new partition in freed space", "Создать новый раздел в освободившемся месте", "Crear nueva partición en el espacio liberado"],
        "part.resizeNote": ["Resize preserves data (APFS/HFS+ live).", "Resize данные сохраняет (APFS/HFS+ live).", "Redimensionar conserva los datos (APFS/HFS+)."],
        "part.apply": ["Apply", "Применить", "Aplicar"],
        "part.addTitle": ["Add partition (from %@)", "Добавить раздел (за счёт %@)", "Añadir partición (desde %@)"],
        "part.shrinkNote": ["Current volume: %@ — will be shrunk.", "Текущий том: %@ — будет ужат.", "Volumen actual: %@ — se reducirá."],
        "part.shrinkTo": ["Shrink existing to (e.g. 200G)", "Ужать существующий до (напр. 200G)", "Reducir el existente a (p.ej. 200G)"],
        "part.newFs": ["New FS", "ФС нового", "FS nuevo"],
        "part.deleteConfirm": ["Delete partition %@? Data will be lost; space goes to the previous partition.", "Удалить раздел %@? Данные будут потеряны, место отойдёт предыдущему разделу.", "¿Eliminar la partición %@? Se perderán los datos; el espacio pasa a la partición anterior."],
        // language
        "lang.menu": ["Language", "Язык", "Idioma"],
        // units & dynamic status messages
        "unit.h": ["h", "ч", "h"],
        "status.running": ["Running…", "Выполняется…", "En curso…"],
        "status.done": ["done", "готово", "hecho"],
        "status.error": ["error", "ошибка", "error"],
        "status.noreply": ["no reply from engine", "нет ответа от движка", "sin respuesta del motor"],
        "export.saving": ["Saving…", "Сохранение…", "Guardando…"],
        "export.saved": ["Saved: %@", "Сохранено: %@", "Guardado: %@"],
        "export.failed": ["Couldn't save (Full Disk Access needed?)", "Не удалось сохранить (нужен Full Disk Access?)", "No se pudo guardar (¿se requiere Acceso Total al Disco?)"],
        "scan.summary": ["average %@ ms · max %d ms · slow/errors: %d · %@",
                          "средняя %@ мс · наибольшая %d мс · медленных/ошибок: %d · %@",
                          "media %@ ms · máx %d ms · lentos/errores: %d · %@"],
    ]
}
