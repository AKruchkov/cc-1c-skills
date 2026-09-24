// platform-dump-sync.test.mjs — db-dump-xml Changes/Full поверх существующей выгрузки, оба движка.
// Changes должен быть инкрементом от ConfigDumpInfo.xml (1cv8 -update, ibcmd --sync), а Full в
// непустой каталог — писать поверх и не трогать лишнее, как конфигуратор (ibcmd сам в непустой
// каталог не выгружает). Изменение доставляется в базу загрузкой частями и проверяется маркером.

export const name = 'Выгрузка поверх существующей: Changes и Full (оба движка)';
export const setup = 'none';
export const requiresPlatform = true;
export const engines = ['1cv8', 'ibcmd'];

export const steps = [
  // ── 1. Минимальная база ──
  {
    name: 'cf-init: пустая конфигурация',
    script: 'cf-init/scripts/cf-init',
    args: { '-Name': 'ВыгрузкаПоверх', '-OutputDir': '{workDir}/config' },
  },
  {
    name: 'meta-compile: Справочник Товары',
    script: 'meta-compile/scripts/meta-compile',
    input: { type: 'Catalog', name: 'Товары', codeLength: 9, descriptionLength: 100 },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}/config' },
  },
  {
    name: 'cf-edit: регистрация справочника',
    script: 'cf-edit/scripts/cf-edit',
    input: [{ operation: 'add-childObject', value: 'Catalog.Товары' }],
    args: { '-ConfigPath': '{workDir}/config', '-DefinitionFile': '{inputFile}' },
  },
  {
    name: 'db-create: файловая ИБ',
    script: 'db-create/scripts/db-create',
    args: { '-V8Path': '{v8path}', '-InfoBasePath': '{workDir}/testdb' },
  },
  {
    name: 'db-load-xml: загрузка конфигурации (Full)',
    script: 'db-load-xml/scripts/db-load-xml',
    args: { '-V8Path': '{v8path}', '-InfoBasePath': '{workDir}/testdb', '-ConfigDir': '{workDir}/config' },
  },

  // ── 2. Первая выгрузка режимом по умолчанию (Changes) в несуществующий каталог → полная ──
  {
    name: 'db-dump-xml: первая выгрузка без -Mode',
    script: 'db-dump-xml/scripts/db-dump-xml',
    args: { '-V8Path': '{v8path}', '-InfoBasePath': '{workDir}/testdb', '-ConfigDir': '{workDir}/dump' },
  },
  {
    name: 'assert: выгрузка содержит ConfigDumpInfo.xml',
    assertContains: '{workDir}/dump/ConfigDumpInfo.xml',
    expect: 'ConfigDumpInfo',
  },

  // ── 3. Изменение в базе → Changes поверх выгрузки ──
  {
    name: 'editFile: маркер в Comment справочника',
    editFile: '{workDir}/config/Catalogs/Товары.xml',
    replace: '<Comment/>',
    with: '<Comment>syncMARK</Comment>',
  },
  {
    name: 'db-load-xml: частичная загрузка Товары',
    script: 'db-load-xml/scripts/db-load-xml',
    args: {
      '-V8Path': '{v8path}', '-InfoBasePath': '{workDir}/testdb',
      '-ConfigDir': '{workDir}/config', '-Files': 'Catalogs/Товары.xml',
    },
  },
  {
    name: 'db-dump-xml: Changes поверх выгрузки',
    script: 'db-dump-xml/scripts/db-dump-xml',
    args: { '-V8Path': '{v8path}', '-InfoBasePath': '{workDir}/testdb', '-ConfigDir': '{workDir}/dump', '-Mode': 'Changes' },
  },
  {
    name: 'assert: Changes выгрузил изменение',
    assertContains: '{workDir}/dump/Catalogs/Товары.xml',
    expect: 'syncMARK',
  },

  // ── 4. Full в непустой каталог: пишет поверх, лишнее остаётся ──
  {
    name: 'meta-compile: посторонний объект в каталоге выгрузки',
    script: 'meta-compile/scripts/meta-compile',
    input: { type: 'Catalog', name: 'Посторонний' },
    args: { '-JsonPath': '{inputFile}', '-OutputDir': '{workDir}/dump' },
  },
  {
    name: 'db-dump-xml: Full в непустой каталог',
    script: 'db-dump-xml/scripts/db-dump-xml',
    args: { '-V8Path': '{v8path}', '-InfoBasePath': '{workDir}/testdb', '-ConfigDir': '{workDir}/dump', '-Mode': 'Full' },
  },
  {
    name: 'assert: Full выгрузил конфигурацию',
    assertContains: '{workDir}/dump/Catalogs/Товары.xml',
    expect: 'syncMARK',
  },
  {
    name: 'assert: посторонний объект не удалён',
    assertContains: '{workDir}/dump/Catalogs/Посторонний.xml',
    expect: 'Посторонний',
  },
];
