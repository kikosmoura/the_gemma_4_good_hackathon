import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hansen_guard/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Widget tests run without Android or LiteRT-LM, so the native Gemma channel
  // is replaced with deterministic responses that exercise the Flutter flow.
  const channel = MethodChannel('com.example.hansen_guard/litert_lm');

  Future<void> pumpPastSplash(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 750));
    await tester.pumpAndSettle();
  }

  Future<void> chooseLanguage(WidgetTester tester, AppLanguage language) async {
    await tester.tap(find.text(language.actionLabel));
    await tester.pumpAndSettle();
  }

  Finder navigationDestinationLabel(String label) {
    return find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    );
  }

  setUp(() async {
    final historyDirectory = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}hansen_guard_history',
    );
    if (await historyDirectory.exists()) {
      await historyDirectory.delete(recursive: true);
    }

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          // Keep the mocked contract aligned with MainActivity so UI tests cover
          // bootstrap, initialization, and structured triage parsing.
          switch (call.method) {
            case 'getRecommendedModelPath':
              return '/storage/emulated/0/Android/data/com.example.hansen_guard/files/gemma-4-E2B-it.litertlm';
            case 'initializeModel':
              return {
                'modelPath':
                    '/storage/emulated/0/Android/data/com.example.hansen_guard/files/gemma-4-E2B-it.litertlm',
                'backend': 'gpu',
                'message': 'Gemma 4 inicializado em GPU no dispositivo.',
              };
            case 'analyzeTriage':
              return {
                'score': 82,
                'riskLevel': 'high',
                'reasoning': [
                  'Area com alteracao de cor persistente na imagem.',
                  'Dormencia relatada aumenta a prioridade de encaminhamento.',
                ],
                'recommendedAction':
                    'Encaminhar para avaliacao clinica prioritaria e testar sensibilidade.',
              };
          }

          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'shows language selection first and unlocks triage in English after adding a patient',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const HansenGuardApp());
      await pumpPastSplash(tester);

      expect(
        find.text('Escolha o idioma\nChoose your language'),
        findsOneWidget,
      );
      await chooseLanguage(tester, AppLanguage.english);

      // After language selection, user lands on the Home dashboard.
      // Navigate to the "New Case" tab to add a patient.
      expect(find.text('Welcome to Hansen Guard'), findsOneWidget);

      await tester.tap(navigationDestinationLabel('New Case'));
      await tester.pumpAndSettle();

      expect(find.text('Add patient'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Name'),
        'Maria Silva',
      );
      await tester.enterText(find.widgetWithText(TextField, 'Age'), '42');
      await tester.ensureVisible(find.text('Add patient and continue'));
      await tester.tap(find.text('Add patient and continue'));
      await tester.pumpAndSettle();

      // After adding patient, the flow auto-advances to photos step
      expect(find.text('Photo protocol'), findsOneWidget);
      expect(find.text('Region 1'), findsOneWidget);
      expect(find.text('Overview photo'), findsOneWidget);
      expect(find.text('Medium photo'), findsOneWidget);
      expect(find.text('Close photo'), findsOneWidget);
      expect(find.text('Adjacent skin comparison'), findsOneWidget);
      expect(find.text('Add another region'), findsOneWidget);
      expect(find.text('Camera'), findsWidgets);
      expect(find.text('Gallery'), findsWidgets);
      expect(find.text('Sample'), findsWidgets);
      expect(find.text('Caso 01'), findsNothing);

      const sampleButton = ValueKey('sample-button-overview');
      await tester.ensureVisible(find.byKey(sampleButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(sampleButton), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.text('Sample images'), findsOneWidget);
      expect(find.text('Case 01'), findsOneWidget);
      expect(find.byType(Image), findsWidgets);
      await tester.drag(find.byType(GridView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(find.text('Case 13'), findsOneWidget);
    },
  );

  testWidgets(
    'filters local history by patient name and opens the details screen',
    (tester) async {
      final savedCase = SavedCaseRecord(
        id: 'case-1',
        patient: const PatientProfile(
          name: 'Maria Silva',
          sex: PatientSex.female,
          age: 42,
        ),
        createdAt: DateTime(2026, 5, 7, 10, 30),
        caseName: 'Caso salvo',
        imagePaths: const ['missing_image_1.png', 'missing_image_2.png'],
        result: const TriageResult(
          score: 82,
          level: RiskLevel.high,
          visualFindings: ['placa hipocromica em area exposta'],
          reasoning: [
            'Dormencia relatada aumenta a prioridade de encaminhamento.',
          ],
          recommendedAction: 'Encaminhar para avaliacao clinica prioritaria.',
          consistencyNote: null,
          scoreAdjusted: false,
        ),
      );

      await tester.pumpWidget(HansenGuardApp(initialSavedCases: [savedCase]));
      await pumpPastSplash(tester);
      await chooseLanguage(tester, AppLanguage.portuguese);

      await tester.tap(navigationDestinationLabel('Historico'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.widgetWithText(TextField, 'Buscar paciente por nome'),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Buscar paciente por nome'),
        'Joao',
      );
      await tester.pump();

      expect(
        find.text('Nenhum paciente encontrado.'),
        findsOneWidget,
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Buscar paciente por nome'),
        'Maria',
      );
      await tester.pump();

      expect(find.text('Maria Silva'), findsOneWidget);

      await tester.ensureVisible(find.text('Maria Silva'));
      await tester.tap(find.text('Maria Silva'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Fotos salvas do paciente'), findsOneWidget);
      expect(find.text('Foto 2'), findsOneWidget);
      expect(find.text('Proxima acao'), findsOneWidget);
    },
  );

  testWidgets('deletes a saved record from the history after confirmation', (
    tester,
  ) async {
    final savedCase = SavedCaseRecord(
      id: 'case-delete',
      patient: const PatientProfile(
        name: 'Joana Souza',
        sex: PatientSex.female,
        age: 37,
      ),
      createdAt: DateTime(2026, 5, 7, 11, 15),
      caseName: 'Caso para excluir',
      imagePaths: const ['missing_image_delete.png'],
      result: const TriageResult(
        score: 55,
        level: RiskLevel.moderate,
        visualFindings: ['mancha hipocromica localizada'],
        reasoning: ['Alteracao de sensibilidade relatada.'],
        recommendedAction: 'Reavaliar presencialmente.',
        consistencyNote: null,
        scoreAdjusted: false,
      ),
    );

    await tester.pumpWidget(HansenGuardApp(initialSavedCases: [savedCase]));
    await pumpPastSplash(tester);
    await chooseLanguage(tester, AppLanguage.portuguese);

    await tester.tap(navigationDestinationLabel('Historico'));
    await tester.pumpAndSettle();

    expect(find.text('Joana Souza'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline_rounded).first);
    await tester.pumpAndSettle();

    expect(find.text('Excluir do historico?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Excluir'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(find.text('Joana Souza'), findsNothing);
    expect(
      find.text('Nenhum caso salvo'),
      findsOneWidget,
    );
  });

  test('triage result parser normalizes native payload', () {
    final result = TriageResult.fromMap({
      'score': '67',
      'risk_level': 'moderate',
      'image_quality_summary': ['fotos com luz adequada'],
      'region_findings': [
        {
          'region': 'Regiao 1',
          'image_quality': 'boa',
          'findings': ['bordas discretas', 'hipocromia localizada'],
        },
      ],
      'visual_risk_score': 52,
      'visual_risk_level': 'moderate',
      'clinical_neural_risk_score': 67,
      'clinical_neural_risk_level': 'moderate',
      'visual_findings': ['bordas discretas', 'hipocromia localizada'],
      'relevant_symptoms': ['mudanca de cor relatada'],
      'risk_factors': ['persistencia acima de 3 meses'],
      'reasoning': ['Mancha persistente', 'Mudanca de cor relatada'],
      'referral_reason': 'Lesao persistente com mudanca de cor.',
      'next_action': 'Agendar avaliacao presencial.',
      'recommended_action': 'Agendar avaliacao presencial.',
      'consistency_note': 'Score elevado por consistencia clinica.',
      'score_adjusted': true,
    });

    expect(result.level, RiskLevel.moderate);
    expect(result.score, 67);
    expect(result.imageQualitySummary, hasLength(1));
    expect(result.regionFindings, hasLength(1));
    expect(result.visualRiskScore, 52);
    expect(result.clinicalNeuralRiskScore, 67);
    expect(result.relevantSymptoms, contains('mudanca de cor relatada'));
    expect(result.riskFactors, contains('persistencia acima de 3 meses'));
    expect(result.visualFindings, hasLength(2));
    expect(result.reasoning, hasLength(2));
    expect(result.referralReason, 'Lesao persistente com mudanca de cor.');
    expect(result.nextAction, 'Agendar avaliacao presencial.');
    expect(result.recommendedAction, 'Agendar avaliacao presencial.');
    expect(result.consistencyNote, 'Score elevado por consistencia clinica.');
    expect(result.scoreAdjusted, isTrue);
  });

  test('triage result parser supports insufficient image class', () {
    final result = TriageResult.fromMap({
      'score': 0,
      'risk_level': 'insufficient_image',
      'visual_risk_level': 'insufficient_image',
      'clinical_neural_risk_level': 'low',
      'image_quality_summary': ['imagem escura e sem foco suficiente'],
      'next_action': 'Refazer fotos do protocolo com luz uniforme.',
      'reasoning': ['A imagem nao permite avaliar bordas e textura.'],
    });

    expect(result.level, RiskLevel.insufficientImage);
    expect(result.visualRiskLevel, RiskLevel.insufficientImage);
    expect(result.nextAction, 'Refazer fotos do protocolo com luz uniforme.');
  });

  test(
    'triage result parser separates increasing and non-increasing factors',
    () {
      final result = TriageResult.fromMap({
        'score': 55,
        'risk_level': 'moderate',
        'risk_factors': [
          'Ausencia de achados visuais dermatologicos sugestivos',
          'qualidade visual insuficiente',
          'fraqueza muscular',
        ],
        'reasoning': ['Sinal clinico-neural relatado.'],
        'next_action': 'Encaminhar para avaliacao presencial.',
      });

      expect(result.riskFactors, ['fraqueza muscular']);
      expect(result.confidenceLimitingFactors, [
        'qualidade visual insuficiente',
      ]);
      expect(result.reassuringFactors, [
        'Ausencia de achados visuais dermatologicos sugestivos',
      ]);
    },
  );

  test('triage result parser hides positive technical quality markers', () {
    final result = TriageResult.fromMap({
      'score': 62,
      'risk_level': 'moderate',
      'image_quality_summary': ['Qualidade tecnica boa'],
      'region_findings': [
        {
          'region': 'Regiao 1',
          'image_quality': 'boa',
          'findings': ['Qualidade tecnica boa', 'placa hipocromica discreta'],
        },
      ],
      'visual_findings': ['placa hipocromica discreta'],
      'reasoning': ['Achado visual persistente.'],
      'recommended_action': 'Encaminhar.',
    });

    expect(result.imageQualitySummary, isEmpty);
    expect(result.regionFindings.single.imageQuality, isEmpty);
    expect(result.regionFindings.single.findings, ['placa hipocromica discreta']);
  });

  test(
    'triage result parser strips embedded section labels from partial recovery text',
    () {
      final result = TriageResult.fromMap({
        'score': 55,
        'risk_level': 'moderate',
        'image_quality_summary': [
          'Qualidade das imagens: Resposta local parcialmente recuperada, revisar achados e fatores de confianca e Achados por Regiao: Regiao 1 Qualidade tecnica boa',
        ],
        'visual_findings': [
          'Achados por Regiao: Regiao 1 Qualidade tecnica boa Lesao circular com alteracao de cor na regiao do joelho',
        ],
        'reasoning': ['Raciocinio clinico: correlacionar imagem e sintomas.'],
        'recommended_action': 'Encaminhar para avaliacao clinica.',
      });

      expect(result.imageQualitySummary, [
        'Resposta local parcialmente recuperada, revisar achados e fatores de confianca.',
      ]);
      expect(result.regionFindings, hasLength(1));
      expect(result.regionFindings.single.findings, [
        'Lesao circular com alteracao de cor na regiao do joelho',
      ]);
      expect(result.reasoning, ['correlacionar imagem e sintomas.']);
    },
  );

  test(
    'native analysis payload includes protocol labels and quality notes',
    () async {
      Map<dynamic, dynamic>? sentArguments;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'analyzeTriage') {
              sentArguments = Map<dynamic, dynamic>.from(call.arguments as Map);
              return {
                'score': 40,
                'riskLevel': 'low',
                'reasoning': ['Imagem avaliada com protocolo fotografico.'],
                'recommendedAction': 'Reavaliar se houver piora.',
              };
            }

            return null;
          });

      await const LiteRtTriageEngine().analyze(
        TriageInput(
          language: AppLanguage.portuguese,
          caseName: 'Protocolo fotografico da regiao 1',
          region: 'Regiao 1 do corpo',
          visualSummary: 'protocolo fotografico guiado',
          imageBytesList: [
            Uint8List.fromList([1, 2, 3]),
          ],
          imageLabels: ['Regiao 1 - Foto geral (camera)'],
          imageQualityNotes: ['validacao local sem alertas'],
          hasNumbness: false,
          changedColor: true,
          hasContactWithConfirmedCase: false,
          hasNervePainOrShock: false,
          hasMuscleWeakness: false,
          hasDrynessOrHairLoss: false,
          hasMultipleLesions: false,
          hasWoundOrBurnWithoutPain: false,
          notes: '',
          duration: DurationOption.lessThan3Months,
        ),
      );

      expect(sentArguments?['imageLabels'], ['Regiao 1 - Foto geral (camera)']);
      expect(sentArguments?['imageQualityNotes'], [
        'validacao local sem alertas',
      ]);
      expect(sentArguments?['languageCode'], 'pt');
      expect(sentArguments?['durationKey'], 'lessThan3Months');
    },
  );

  test('local repository saves patient images and analysis records', () async {
    final repository = LocalCaseRepository();
    final savedRecord = await repository.saveCase(
      patient: const PatientProfile(
        name: 'Maria Silva',
        sex: PatientSex.female,
        age: 42,
      ),
      caseName: 'Caso salvo',
      imageBytesList: [
        Uint8List.fromList([1, 2, 3, 4]),
      ],
      result: const TriageResult(
        score: 82,
        level: RiskLevel.high,
        visualFindings: ['placa hipocromica em area exposta'],
        reasoning: ['Dormencia relatada aumenta a prioridade.'],
        recommendedAction: 'Encaminhar para avaliacao clinica.',
        consistencyNote: null,
        scoreAdjusted: false,
      ),
    );

    final records = await repository.loadCases();

    expect(records, hasLength(1));
    expect(records.single.patient.name, 'Maria Silva');
    expect(records.single.result.level, RiskLevel.high);
    expect(records.single.imagePaths, hasLength(1));
    expect(await File(savedRecord.imagePaths.single).exists(), isTrue);
  });

  test('local repository deletes saved records and image files', () async {
    final repository = LocalCaseRepository();
    final savedRecord = await repository.saveCase(
      patient: const PatientProfile(
        name: 'Joana Souza',
        sex: PatientSex.female,
        age: 37,
      ),
      caseName: 'Caso para excluir',
      imageBytesList: [
        Uint8List.fromList([9, 8, 7, 6]),
      ],
      result: const TriageResult(
        score: 55,
        level: RiskLevel.moderate,
        visualFindings: ['mancha hipocromica localizada'],
        reasoning: ['Alteracao de sensibilidade relatada.'],
        recommendedAction: 'Reavaliar presencialmente.',
        consistencyNote: null,
        scoreAdjusted: false,
      ),
    );

    final imageDirectory = Directory(
      File(savedRecord.imagePaths.single).parent.path,
    );

    await repository.deleteCase(savedRecord.id);
    final records = await repository.loadCases();

    expect(records, isEmpty);
    expect(await imageDirectory.exists(), isFalse);
  });
}
