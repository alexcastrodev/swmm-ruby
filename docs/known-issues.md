# Bugs conhecidos

A gem usa o **motor oficial da EPA, SWMM 5.2.4, sem alterações** (`rake swmm:build` baixa e compila o código da EPA). Dois defeitos desse motor têm causa raiz identificada e **não são corrigidos pela gem, por decisão do projeto**: ficam documentados aqui, com o jeito de reconhecê-los e de contorná-los. Os dois fazem o motor terminar "com sucesso" (`result.ok? == true`) entregando dados errados, sem aviso.

Estado do upstream verificado em 2026-10-16: a última release da EPA é a v5.2.4 (2023-10-10) e nenhum dos dois defeitos está corrigido nela, no `develop` nem no `master`.

## 1. O último período de relatório às vezes não é gravado

**Sintoma.** Em cerca de 1 janela de simulação em 3, o `.out` não tem o último período. Exemplo: das 11:00 às 13:00 do dia 2022-11-27, com relatório a cada 10 minutos, saem 11 períodos (o último às 12:50) em vez de 12. Das 00:00 às 02:00 do dia 2026-03-24 saem os 12. O resultado independe de plataforma e do passo de relatório ou de roteamento; depende só da data e hora de início e de fim. O mesmo acontece com o `swmm5` de linha de comando e com `swmm_run`. Nada no `Result` avisa.

**Como reconhecer.** `result.times.last` fica um passo de relatório antes do fim configurado em `options` (`end_date` + `end_time`).

**Contorno (verificado).** Terminar a simulação **um segundo depois**: `end_time: "13:00:01"` em vez de `"13:00"`. O segundo extra não acrescenta período e não altera nenhum dos outros (testado em 98 de 98 janelas que perdiam o período; os 11 primeiros períodos saíram idênticos). Há um teste: `test_ending_one_second_later_saves_the_last_period`.

**Causa.** `src/solver/project.c:165`:

```c
TotalDuration = floor((EndDateTime - StartDateTime) * SECperDAY);
```

Cada `DateTime` é um número de série de data (~4,5e4 dias) mais a fração do dia, arredondado ao `double` mais próximo. A diferença pode sair um pouco abaixo do intervalo real, e o `floor` perde um segundo inteiro. Para 2022-11-27 11:00 a 13:00 a conta dá 7199,9999995809 s (o certo seria 7200), então o instante de relatório de 7200 s fica fora da simulação e seu período nunca é gravado. A regra "perde o período exatamente quando o `floor` fica abaixo do intervalo real, em IEEE" concordou com o motor em 900 de 900 janelas.

**Correção de uma linha (não aplicada).** Com uma tolerância de 1 ms (o erro é de no máximo ~1e-4 s mesmo no ano 9999):

```diff
-        TotalDuration = floor((EndDateTime - StartDateTime) * SECperDAY);
+        TotalDuration = floor((EndDateTime - StartDateTime) * SECperDAY + 0.001);
```

Com ela, 300 de 300 janelas aleatórias de 2 horas saíram com os 12 períodos (sem ela, 98 de 300 saíam com 11), e as 202 janelas que já estavam certas produziram `.out` idêntico byte a byte. Em 20 000 janelas aleatórias de 1 a 40 horas, a fórmula original erra em 33,8% e esta em 0.

**Upstream.** Issue [#152](https://github.com/USEPA/Stormwater-Management-Model/issues/152) (fechada), PR [#179](https://github.com/USEPA/Stormwater-Management-Model/pull/179) "PR for 5.3.0 release" (aberto, não mergeado; traz o commit 57cf5fa nos ramos `bug_fixes` e `perf_imprv`) e o fork OpenWaterAnalytics (usado por pyswmm e swmm-toolkit) já trocaram a fórmula por `floor(dData*86400 + dHora*86400)`. Essa forma é só uma melhora: erra em 6,8% das mesmas 20 000 janelas (e ainda erra o caso 2022-11-27 11:00 a 13:00, que dá 7199,99999999999…). Ela não está em nenhuma release.

## 2. Execuções idênticas dão resultados diferentes (snowpack)

**Sintoma.** Em Linux, de ~1,5% a 2,7% das execuções idênticas de um modelo cujo subcatchment usa um snowpack saem com outro resultado: continuidade de runoff `NaN`, runoff do subcatchment todo zero, e a continuidade de routing e de qualidade diferente (no modelo de teste: routing 6,4177% em vez de 5,966%, qualidade −51,13% em vez de −50,64%). No macOS não apareceu em 1200 execuções. Linha de base medida: aarch64 de 1,5% a 2,4%; x86_64 16 erradas em 600 (2,7%).

**Quando acontece.** O snowpack é usado por um subcatchment e tem uma superfície com área zero: fração plowável 0 ou 1, ou um subcatchment 0% ou 100% impermeável. Um snowpack definido mas sem uso não é afetado (0 erros em 800 execuções).

**Como reconhecer.** `result.continuity[:runoff].nan?` (então `result.continuity_ok?` é `false`). No dado exportado (`to_h`, `to_json`) esse valor aparece como `null`.

**Contorno.** O erro é aleatório por execução: repetir a simulação quando a continuidade sair `NaN` resolve, na maioria das vezes (~98%).

**Causa.** `snow_createSnowpack` (`snow.c:135`) aloca o snowpack com `malloc` e `snow_initSnowpack` (`snow.c:171-187`) inicializa todos os campos por superfície, **menos `imelt[]`**. O `imelt[i]` só é escrito em `snow_plowSnow` (`snow.c:385-392`), e só para superfícies de área maior que zero. Mas `snow_getSnowMelt` o lê sempre: `imelt[i] +=` (linha 493) e `netPrecip[i] = smelt + imelt[i] + …` (linha 510). Numa superfície de área zero ele fica com o que havia no heap; se forem bytes de `NaN` ou `Infinity`, `NaN × 0` (a área) é `NaN` e chega ao runoff e à continuidade. O `glibc` entrega blocos reciclados, por isso só aparece em Linux; o macOS devolve blocos pequenos zerados. Provado com `valgrind --track-origins=yes` (todos os erros nascem em `snow.c:135`; com a linha abaixo, 0 erros) e com `valgrind --malloc-fill=0xff` (3 de 3 execuções falham sem a linha, 3 de 3 passam com ela).

**Correção de uma linha (não aplicada).**

```diff
         snowpack->awe[i]   = 1.0;
+        snowpack->imelt[i] = 0.0;
         snowDepth += snowpack->wsnow[i] * snowpack->fArea[i];
```

Com ela: 0 erros em 1800 execuções no aarch64 e em 600 no x86_64, todas iguais ao resultado de referência do macOS (runoff máximo do S1 62,38755; continuidade −0,4178 / 5,966 / −50,6426). Os modelos sem snowpack produzem `.out` idênticos com e sem a linha.

**Upstream.** Não encontrei nenhuma issue nem PR (buscas por `imelt`, "snow uninitialized", "snow valgrind"); `snow_initSnowpack` não inicializa o `imelt` na v5.2.4, em `develop`, `master`, `bug_fixes`, `perf_imprv` e no fork OpenWaterAnalytics.

**Outro defeito latente no mesmo arquivo.** `sba[]` e `sbws[]` também não são inicializados. Só são lidos depois de um `USE HOTSTART` (que restaura `awe` mas não os dois). O valor certo é uma escolha de modelagem; não foi investigado mais.

## Como reproduzir

```sh
SWMM_SHOW_BUGS=1 rake test        # executa os testes que descrevem o comportamento correto e falham com o motor como é lançado
```

- Bug 1: `KnownEngineBugsTest#test_the_last_reporting_period_is_saved` (falha em qualquer plataforma) e `EngineOracleTest#test_the_period_on_the_end_date_can_be_missing_because_of_the_engine`, que sempre roda e fixa o comportamento atual: se o motor for corrigido, ele falha e avisa que este documento deve ser revisto.
- Bug 2: `KnownEngineBugsTest#test_a_snowpack_with_a_zero_area_surface_does_not_read_recycled_heap`. Enche de bytes `0xFF` (`NaN` como `double`) blocos que depois libera, para o `malloc` os reciclar: falha em cerca de metade das 24 execuções em Linux aarch64 e x86_64; no macOS passa, porque o `malloc` de lá não recicla os blocos.

## Correção preparada (não aplicada na gem)

Há uma branch pronta para o projeto da EPA, no fork de `alexcastrodev`: [`fix/last-report-period-and-snow-imelt`](https://github.com/alexcastrodev/Stormwater-Management-Model/tree/fix/last-report-period-and-snow-imelt), com **dois commits sobre o `develop`**, um por bug. Cada um traz a correção de uma linha e um teste novo em `tests/solver` (Boost Test) que **simula o bug**:

- **`TotalDuration`:** roda a janela 2022-11-27 11:00 a 13:00 e confere que o `.out` tem 12 períodos (sem a correção, 11).
- **`imelt`:** roda o modelo do snowpack com e sem um `malloc` que enche cada bloco novo de `0xFF` (como `valgrind --malloc-fill=0xff`; só em glibc, o executável de teste define o `malloc` que a `libswmm5` chama) e confere que a continuidade é finita e igual nas duas (sem a correção: `-nan`).

Verificado em Linux (aarch64, `debian:stable`, cmake + Boost.Test): sem as correções o `test_solver` falha com 4 asserções (`11 != 12`; `-nan != -0.5426`; routing `9.99e-07 != 0.394`); com elas passa, e cada commit passa sozinho. `valgrind --track-origins=yes --malloc-fill=0xff` no modelo do teste: sem a correção 1108 erros em 43 contextos, todos criados em `snow_createSnowpack (snow.c:135)`; com ela, 0. O `test_output` da EPA passa nas duas versões quando executado direto (o registro dele no `ctest` falha em Linux de configuração única, por causa do caminho `bin/$<CONFIGURATION>` do `tests/CMakeLists.txt` deles; o `test_solver` é registrado pelo nome do alvo e não tem esse problema).

Nenhum PR foi aberto no repositório da EPA. Para abrir um: <https://github.com/USEPA/Stormwater-Management-Model/compare/develop...alexcastrodev:Stormwater-Management-Model:fix/last-report-period-and-snow-imelt>.

## Se você quiser os dois consertos no seu build

A gem não os aplica. Para compilar a lib com eles, use a branch acima (`git clone --branch fix/last-report-period-and-snow-imelt https://github.com/alexcastrodev/Stormwater-Management-Model.git`, `cmake`, e aponte `SWMM_LIB` para a `libswmm5` gerada), ou aplique os dois diffs deste documento ao código da EPA. Com uma lib assim, os testes do bug 1 e do bug 2 passam com `SWMM_SHOW_BUGS=1` e o teste que fixa o bug 1 (`EngineOracleTest`) deixa de passar.
