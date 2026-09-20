# CommonModule, ScheduledJob, EventSubscription (объекты, привязанные к коду)

## CommonModule (Общий модуль)

Флаги контекста выполнения (все bool, по умолчанию `false`). Создаёт пустой `Ext/Module.bsl`.

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `context` | — | шорткат флагов (см. ниже) |
| `global` | `false` | bool |
| `server` | `false` | bool |
| `serverCall` | `false` | bool (вызов сервера) |
| `clientManagedApplication` | `false` | bool (клиент управляемого приложения) |
| `clientOrdinaryApplication` | `false` | bool (клиент обычного приложения) |
| `externalConnection` | `false` | bool |
| `privileged` | `false` | bool |
| `returnValuesReuse` | `DontUse` | `DontUse` / `DuringRequest` / `DuringSession` |

Шорткат `context`: `"server"` → Server+ServerCall; `"client"` → ClientManagedApplication;
`"serverClient"` → Server+ClientManagedApplication.

```json
{ "type": "CommonModule", "name": "ОбменДаннымиСервер", "context": "server", "returnValuesReuse": "DuringRequest" }
```

## ScheduledJob (Регламентное задание)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `methodName` | пусто | метод-обработчик `"МодульСервер.Процедура"` (дополняется до `CommonModule.…`) |
| `description` | пусто | наименование задания |
| `key` | пусто | ключ |
| `use` | `false` | bool (использование) |
| `predefined` | `false` | bool (предопределённое) |
| `restartCountOnFailure` | `3` | число повторов при сбое |
| `restartIntervalOnFailure` | `10` | интервал повтора, сек |

```json
{ "type": "ScheduledJob", "name": "ОбменДанными", "methodName": "ОбменДаннымиСервер.Выполнить", "use": true }
```

## EventSubscription (Подписка на событие)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `source` | `[]` | объекты-источники (формы ниже): `["CatalogObject.Контрагенты", "DocumentObject.Реализация"]` |
| `event` | `BeforeWrite` | `BeforeWrite` / `OnWrite` / `BeforeDelete` / `OnReadAtServer` / `FillCheckProcessing` … |
| `handler` | пусто | метод-обработчик `"МодульСервер.Процедура"` (дополняется до `CommonModule.…`) |

```json
{ "type": "EventSubscription", "name": "ПередЗаписьюКонтрагента",
  "source": ["CatalogObject.Контрагенты"], "event": "BeforeWrite",
  "handler": "ОбщегоНазначенияСервер.ПередЗаписьюКонтрагента" }
```

**Формы источника.** Кроме конкретного объекта (`DocumentObject.Реализация`) источник бывает:

| Форма | Смысл | Пример |
|-------|-------|--------|
| голый объектный вид | ВСЕ объекты класса | `"DocumentObject"`, `"CatalogObject"`, `"InformationRegisterRecordSet"`, `"ConstantValueManager"` |
| `DefinedType.<Имя>` | состав определяемого типа | `"DefinedType.ПрисоединенныйФайлОбъект"` |
| `Characteristic.<Имя>` | значение характеристики ПВХ | `"Characteristic.ДополнительныеРеквизитыИСведения"` |
| менеджер объекта | сам менеджер, не класс | `"DocumentManager.Реализация"`, `"CatalogManager.Контрагенты"` |

В типовых конфигурациях источник чаще задан классом или определяемым типом, чем перечислением:
в выгрузке ERP так задана треть подписок. Русские имена принимаются наравне с английскими
(`"ДокументОбъект"`, `"ОпределяемыйТип.Коллекция"`).

```json
{ "type": "EventSubscription", "name": "ПроверкаЗаполненияЛюбогоДокумента",
  "source": ["DocumentObject", "DefinedType.ПрисоединенныйФайлОбъект"],
  "event": "FillCheckProcessing", "handler": "ОбщегоНазначенияСервер.ПроверитьЗаполнение" }
```

> Процедура-обработчик (`methodName` / `handler`) должна существовать в указанном общем модуле (экспортная).
