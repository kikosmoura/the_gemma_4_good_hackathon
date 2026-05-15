# Hansen Guard

Protótipo Flutter offline-first para triagem comunitária de suspeita de hanseníase.

## O que esta versão faz

- Carrega as imagens locais copiadas de `../imagens_hanseniase`.
- Guia o agente por três perguntas: dormência, mudança de cor e tempo da lesão.
- Calcula um nível de suspeita localmente e mostra raciocínio + ação sugerida.
- Mantém avisos explícitos de segurança: o app não diagnostica e não substitui avaliação presencial.

## Como rodar no emulador

```bash
cd hansen_guard_app
flutter run -d emulator-5554
```

Para uma execução que instala e sai do processo do Flutter:

```bash
flutter run -d emulator-5554 --no-resident
```

## Validação

```bash
flutter analyze
flutter test
```

## Arquitetura Gemma 4 offline

- O Flutter monta o fluxo de cadastro, protocolo fotografico, perguntas clinicas e exibicao do resultado em `lib/main.dart`.
- O Android recebe esse payload pelo `MethodChannel` `com.example.hansen_guard/litert_lm`, inicializa o LiteRT-LM e executa o Gemma 4 localmente em `android/app/src/main/kotlin/com/example/hansen_guard/MainActivity.kt`.
- O prompt enviado ao modelo combina imagens, rotulos do protocolo, alertas locais de qualidade e sinais clinicos para separar risco visual dermatologico de risco clinico-neural.
- Se o Gemma devolver JSON malformado, o lado Android tenta um reparo local e, em ultimo caso, recupera os fragmentos mais uteis antes de aplicar guardrails clinicas deterministicas.

## Fluxo resumido do modelo

1. `main.dart` resolve o caminho recomendado do arquivo `.litertlm` e tenta inicializar o motor nativo logo na abertura do app.
2. O protocolo fotografa ate 2 regioes com 3 fotos obrigatorias por regiao para caber na janela multimodal do Gemma 4 offline.
3. Antes de enviar ao modelo, o app calcula heuristicas locais de qualidade da foto e inclui esses avisos no prompt como contexto de confianca.
4. `MainActivity.kt` monta o prompt final, executa o Gemma 4, valida/repara o JSON e devolve um mapa que `TriageResult.fromMap()` transforma em resultado de UI.

## Scripts de apoio

- `scripts/download_gemma4_e2b.sh`: baixa o artefato LiteRT-LM com o nome esperado pelo app.
- `scripts/push_model_and_install.sh`: gera o APK de debug, instala no aparelho e envia o modelo para o mesmo caminho sugerido por `getRecommendedModelPath()`.

## Próxima etapa técnica

O motor atual é `PrototypeGemmaTriageEngine`, em `lib/main.dart`. Ele foi deixado isolado para ser substituído por uma integração nativa Android via platform channel usando Gemma 4 E2B/E4B em LiteRT-LM ou Android AICore quando o artefato do modelo e um dispositivo ARM64 real estiverem disponíveis.
