# Hansen Guard

Offline-first Flutter prototype for community screening of suspected leprosy.

## What This Version Does

- Loads local reference images copied from `../imagens_hanseniase`.
- Guides the health worker through three core questions: numbness, color change, and lesion duration.
- Computes a local suspicion level and shows reasoning plus the suggested next action.
- Keeps explicit safety warnings visible: the app does not diagnose and does not replace in-person evaluation.

## How To Run On An Emulator

```bash
cd hansen_guard_app
flutter run -d emulator-5554
```

For a run that installs the app and exits the Flutter process immediately:

```bash
flutter run -d emulator-5554 --no-resident
```

## Validation

```bash
flutter analyze
flutter test
```

## Offline Gemma 4 Architecture

- Flutter builds the registration flow, photo protocol, clinical questionnaire, and result presentation in `lib/main.dart`.
- Android receives that payload through the `MethodChannel` `com.example.hansen_guard/litert_lm`, initializes LiteRT-LM, and runs Gemma 4 locally in `android/app/src/main/kotlin/com/example/hansen_guard/MainActivity.kt`.
- The model prompt combines images, protocol labels, local quality warnings, and clinical signals so visual dermatologic risk stays separate from clinical-neural risk.
- If Gemma returns malformed JSON, the Android side first attempts a local repair pass and, as a final fallback, salvages the most useful fragments before applying deterministic clinical guardrails.

## Model Flow Summary

1. `main.dart` resolves the recommended `.litertlm` path and tries to initialize the native engine as soon as the app starts.
2. The photo protocol captures up to 2 regions with 3 required photos per region so the request stays within the offline Gemma 4 multimodal context budget.
3. Before the request is sent, the app computes lightweight local photo-quality heuristics and adds those warnings to the prompt as confidence context.
4. `MainActivity.kt` builds the final prompt, runs Gemma 4, validates or repairs the JSON, and returns a payload that `TriageResult.fromMap()` converts into UI state.

## Support Scripts

- `scripts/download_gemma4_e2b.sh`: downloads the LiteRT-LM artifact using the exact filename expected by the app.
- `scripts/push_model_and_install.sh`: builds the debug APK, installs it on the device, and pushes the model to the same path returned by `getRecommendedModelPath()`.

## Current Implementation Note

The current implementation uses `LiteRtTriageEngine` in `lib/main.dart` plus the native Android bridge in `android/app/src/main/kotlin/com/example/hansen_guard/MainActivity.kt`. The architecture is already structured around on-device Gemma 4 E2B LiteRT-LM execution, with room to swap in a different Android backend such as AICore if the deployment target changes.
