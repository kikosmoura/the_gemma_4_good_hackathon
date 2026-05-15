import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

// Flutter entrypoint for the offline Hansen Guard app. The UI layer collects
// the photo protocol and questionnaire, then delegates Gemma 4 execution to
// the native Android LiteRT-LM bridge further down in this file.
void main() {
  runApp(const HansenGuardApp());
}

class HansenGuardApp extends StatelessWidget {
  const HansenGuardApp({
    super.key,
    this.initialSavedCases = const <SavedCaseRecord>[],
  });

  final List<SavedCaseRecord> initialSavedCases;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0F766E),
      brightness: Brightness.light,
    );

    return MaterialApp(
      title: 'Hansen Guard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFFF5F7F6),
        appBarTheme: AppBarTheme(
          elevation: 0,
          scrolledUnderElevation: 1,
          backgroundColor: colorScheme.surface,
          foregroundColor: colorScheme.onSurface,
          centerTitle: false,
          titleTextStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFE2E8F0), width: 1),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF8FAFB),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colorScheme.primary, width: 2),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            side: BorderSide(color: colorScheme.outline.withValues(alpha: 0.4)),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          elevation: 2,
          height: 72,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          indicatorColor: colorScheme.primaryContainer,
          iconTheme: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return IconThemeData(
                color: colorScheme.onPrimaryContainer,
                size: 24,
              );
            }
            return const IconThemeData(color: Color(0xFF64748B), size: 24);
          }),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: colorScheme.primary,
              );
            }
            return const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Color(0xFF64748B),
            );
          }),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFFE2E8F0),
          space: 1,
          thickness: 1,
        ),
        chipTheme: ChipThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          side: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      home: TriageScreen(initialSavedCases: initialSavedCases),
    );
  }
}

String _tr(BuildContext context, String portuguese, String english) {
  return AppLanguageScope.of(context).pick(portuguese, english);
}

String _localizedQualityWarning(String warning, AppLanguage language) {
  final normalized = warning.trim().toLowerCase();
  return switch (normalized) {
    'baixa resolucao' => language.pick('baixa resolucao', 'low resolution'),
    'pouca luz' => language.pick('pouca luz', 'low light'),
    'excesso de luz ou reflexo' => language.pick(
      'excesso de luz ou reflexo',
      'too much light or glare',
    ),
    'baixo contraste' => language.pick('baixo contraste', 'low contrast'),
    'possivel desfoque ou tremor' => language.pick(
      'possivel desfoque ou tremor',
      'possible blur or motion shake',
    ),
    'sombra forte ou iluminacao irregular' => language.pick(
      'sombra forte ou iluminacao irregular',
      'strong shadow or uneven lighting',
    ),
    'nao foi possivel ler os pixels da imagem' => language.pick(
      'nao foi possivel ler os pixels da imagem',
      'could not read image pixels',
    ),
    'qualidade nao avaliada' => language.pick(
      'qualidade nao avaliada',
      'quality not evaluated',
    ),
    _ => warning,
  };
}

enum DurationOption {
  lessThan3Months('Menos de 3 meses', '< 3 meses'),
  between3And12Months('3 a 12 meses', '3-12 meses'),
  moreThan12Months('Mais de 12 meses', '> 12 meses');

  const DurationOption(this.label, this.shortLabel);

  final String label;
  final String shortLabel;
}

extension DurationOptionLocalization on DurationOption {
  String labelFor(AppLanguage language) {
    return switch (this) {
      DurationOption.lessThan3Months => language.pick(
        'Menos de 3 meses',
        'Less than 3 months',
      ),
      DurationOption.between3And12Months => language.pick(
        '3 a 12 meses',
        '3 to 12 months',
      ),
      DurationOption.moreThan12Months => language.pick(
        'Mais de 12 meses',
        'More than 12 months',
      ),
    };
  }

  String shortLabelFor(AppLanguage language) {
    return switch (this) {
      DurationOption.lessThan3Months => language.pick(
        '< 3 meses',
        '< 3 months',
      ),
      DurationOption.between3And12Months => language.pick(
        '3-12 meses',
        '3-12 months',
      ),
      DurationOption.moreThan12Months => language.pick(
        '> 12 meses',
        '> 12 months',
      ),
    };
  }
}

enum LiteRtBackend {
  gpu('GPU', 'gpu'),
  cpu('CPU', 'cpu');

  const LiteRtBackend(this.label, this.wireValue);

  final String label;
  final String wireValue;
}

enum RiskLevel {
  low('Baixa suspeita', Color(0xFF2D6B43), Icons.check_circle_outline),
  moderate('Suspeita moderada', Color(0xFF9A5D00), Icons.warning_amber_rounded),
  high('Alta suspeita', Color(0xFFB3261E), Icons.priority_high_rounded),
  insufficientImage(
    'Imagem insuficiente',
    Color(0xFF5D6060),
    Icons.hide_image_outlined,
  );

  const RiskLevel(this.label, this.color, this.icon);

  final String label;
  final Color color;
  final IconData icon;
}

extension RiskLevelLocalization on RiskLevel {
  String labelFor(AppLanguage language) {
    return switch (this) {
      RiskLevel.low => language.pick('Baixa suspeita', 'Low suspicion'),
      RiskLevel.moderate => language.pick(
        'Suspeita moderada',
        'Moderate suspicion',
      ),
      RiskLevel.high => language.pick('Alta suspeita', 'High suspicion'),
      RiskLevel.insufficientImage => language.pick(
        'Imagem insuficiente',
        'Insufficient image',
      ),
    };
  }
}

RiskLevel riskLevelFromWire(String raw, {int? fallbackScore}) {
  switch (raw.trim().toLowerCase()) {
    case 'low':
    case 'baixo':
    case 'baixa':
      return RiskLevel.low;
    case 'moderate':
    case 'medium':
    case 'moderado':
    case 'moderada':
      return RiskLevel.moderate;
    case 'high':
    case 'alto':
    case 'alta':
      return RiskLevel.high;
    case 'insufficient':
    case 'insufficient_image':
    case 'insufficientimage':
    case 'image_insufficient':
    case 'imagem_insuficiente':
    case 'imagem insuficiente':
      return RiskLevel.insufficientImage;
    default:
      if (fallbackScore == null) {
        return RiskLevel.low;
      }
      if (fallbackScore >= 70) {
        return RiskLevel.high;
      }
      if (fallbackScore >= 45) {
        return RiskLevel.moderate;
      }
      return RiskLevel.low;
  }
}

List<String> _parseStringList(dynamic raw) {
  if (raw is! List) {
    return const <String>[];
  }

  return raw
      .map((item) => '$item')
      .where((item) => item.trim().isNotEmpty)
      .toList();
}

const List<String> _analysisSectionMarkers = <String>[
  'qualidade das imagens:',
  'image quality:',
  'achados por regiao:',
  'region findings:',
  'achados visuais:',
  'visual findings:',
  'raciocinio clinico:',
  'clinical reasoning:',
  'sintomas relevantes:',
  'relevant symptoms:',
];

String _stripAnalysisSectionLabels(String raw) {
  var value = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  while (value.isNotEmpty) {
    final normalized = _normalizedFactorText(value);
    String? matchedMarker;
    for (final marker in _analysisSectionMarkers) {
      if (normalized.startsWith(marker)) {
        matchedMarker = marker;
        break;
      }
    }
    if (matchedMarker == null) {
      break;
    }
    value = value.substring(matchedMarker.length).trimLeft();
  }

  final normalized = _normalizedFactorText(value);
  int? nextMarkerIndex;
  for (final marker in _analysisSectionMarkers) {
    final markerIndex = normalized.indexOf(marker);
    if (markerIndex > 0 &&
        (nextMarkerIndex == null || markerIndex < nextMarkerIndex)) {
      nextMarkerIndex = markerIndex;
    }
  }

  if (nextMarkerIndex != null) {
    value = value.substring(0, nextMarkerIndex).trimRight();
  }

  return value;
}

String _trimAbruptAnalysisEnding(String raw) {
  var value = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (value.isEmpty || value.length < 20 || RegExp(r'[.!?]$').hasMatch(value)) {
    return value;
  }

  var removedTail = false;
  while (value.isNotEmpty) {
    final lastWord = value.split(' ').last;
    final normalizedLastWord = _normalizedFactorText(lastWord);
    final isShortAsciiFragment = RegExp(r'^[A-Za-z]{1,2}$').hasMatch(lastWord);
    final isTrailingStopword = <String>{
      'e',
      'ou',
      'and',
      'or',
      'com',
      'with',
      'de',
      'do',
      'da',
      'of',
      'to',
      'for',
    }.contains(normalizedLastWord);

    if (!isShortAsciiFragment && !isTrailingStopword) {
      break;
    }

    removedTail = true;
    value = value.substring(0, value.length - lastWord.length).trimRight();
    value = value.replaceFirst(RegExp(r'[,:;\-]+$'), '').trimRight();
  }

  if (removedTail && value.isNotEmpty && !RegExp(r'[.!?]$').hasMatch(value)) {
    value = '$value.';
  }

  return value;
}

bool _looksLikePositiveQualityOnly(String value) {
  final normalized = _normalizedFactorText(value);
  final mentionsQuality =
      normalized.contains('qualidade') || normalized.contains('quality');
  final positive =
      normalized.contains('boa') ||
      normalized.contains('adequada') ||
      normalized.contains('good') ||
      normalized.contains('adequate');
  final limiting =
      normalized.contains('limitad') ||
      normalized.contains('insuficient') ||
      normalized.contains('desfoque') ||
      normalized.contains('sombra') ||
      normalized.contains('baixo contraste') ||
      normalized.contains('low light') ||
      normalized.contains('shadow') ||
      normalized.contains('blur');

  return positive &&
      !limiting &&
      (mentionsQuality ||
          normalized == 'boa' ||
          normalized == 'adequada' ||
          normalized == 'good' ||
          normalized == 'adequate');
}

String _sanitizeAnalysisText(
  String raw, {
  bool stripLeadingRegionLabel = false,
}) {
  var value = _stripAnalysisSectionLabels(
    raw,
  ).replaceFirst(RegExp(r'^[\-•]+\s*'), '').trim();

  if (stripLeadingRegionLabel) {
    value = value.replaceFirst(
      RegExp(
        r'^(Regiao|Região|Region)\s*\d+\s*[:\-]?\s*',
        caseSensitive: false,
      ),
      '',
    );
  }

  value = value.replaceFirst(
    RegExp(
      r'^(Qualidade tecnica|Technical quality)\s*[:\-]?\s*(boa|good|adequada|adequate)\s*',
      caseSensitive: false,
    ),
    '',
  );
  value = value.replaceFirst(
    RegExp(
      r'^(Qualidade tecnica|Technical quality)\s*[:\-]?\s*',
      caseSensitive: false,
    ),
    '',
  );

  value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return _trimAbruptAnalysisEnding(value);
}

List<String> _sanitizeAnalysisList(
  List<String> values, {
  bool dropPositiveQuality = false,
  bool stripLeadingRegionLabel = false,
}) {
  return _distinctStrings(
    values
        .map(
          (item) => _sanitizeAnalysisText(
            item,
            stripLeadingRegionLabel: stripLeadingRegionLabel,
          ),
        )
        .where((item) => item.isNotEmpty)
        .where(
          (item) =>
              !dropPositiveQuality || !_looksLikePositiveQualityOnly(item),
        ),
  );
}

String _cleanRegionImageQuality(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return '';
  }

  final normalized = _normalizedFactorText(trimmed);
  if (normalized.startsWith('boa')) {
    return 'boa';
  }
  if (normalized.startsWith('limitada') || normalized.startsWith('limitado')) {
    return 'limitada';
  }
  if (normalized.startsWith('insuficiente')) {
    return 'insuficiente';
  }
  return '';
}

String? _findingTextFromImageQuality(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final separatorIndex = trimmed.indexOf(RegExp(r'\s[-:]\s'));
  if (separatorIndex < 0) {
    return null;
  }

  final possibleFinding = trimmed.substring(separatorIndex + 3).trim();
  if (possibleFinding.isEmpty) {
    return null;
  }

  final normalized = _normalizedFactorText(possibleFinding);
  final looksVisual =
      normalized.contains('lesao') ||
      normalized.contains('mancha') ||
      normalized.contains('eritem') ||
      normalized.contains('vermelh') ||
      normalized.contains('placa') ||
      normalized.contains('textura') ||
      normalized.contains('borda') ||
      normalized.contains('hipocrom') ||
      normalized.contains('hipercrom') ||
      normalized.contains('hiperpigment');

  return looksVisual ? possibleFinding : null;
}

String _localizedImageQualityLabel(BuildContext context, String raw) {
  final quality = _cleanRegionImageQuality(raw);
  return switch (quality) {
    'boa' => _tr(context, 'Qualidade tecnica: boa', 'Technical quality: good'),
    'limitada' => _tr(
      context,
      'Qualidade tecnica: limitada',
      'Technical quality: limited',
    ),
    'insuficiente' => _tr(
      context,
      'Qualidade tecnica: insuficiente',
      'Technical quality: insufficient',
    ),
    _ =>
      raw.trim().isEmpty
          ? _tr(
              context,
              'Qualidade tecnica: nao informada',
              'Technical quality: not provided',
            )
          : _tr(
              context,
              'Qualidade tecnica: ${raw.trim()}',
              'Technical quality: ${raw.trim()}',
            ),
  };
}

List<String> _distinctStrings(Iterable<String> values) {
  final seen = <String>{};
  final items = <String>[];
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      continue;
    }

    final key = _normalizedFactorText(trimmed);
    if (seen.add(key)) {
      items.add(trimmed);
    }
  }
  return items;
}

String _normalizedFactorText(String value) {
  return value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp('[áàãâä]'), 'a')
      .replaceAll(RegExp('[éèêë]'), 'e')
      .replaceAll(RegExp('[íìîï]'), 'i')
      .replaceAll(RegExp('[óòõôö]'), 'o')
      .replaceAll(RegExp('[úùûü]'), 'u')
      .replaceAll('ç', 'c');
}

bool _looksLikeConfidenceLimitation(String value) {
  final normalized = _normalizedFactorText(value);
  return normalized.contains('qualidade') ||
      normalized.contains('insuficient') ||
      normalized.contains('limitad') ||
      normalized.contains('desfoque') ||
      normalized.contains('pouca luz') ||
      normalized.contains('sombra') ||
      normalized.contains('baixo contraste') ||
      normalized.contains('nao foi possivel') ||
      normalized.contains('confianca visual');
}

bool _looksLikeReassuringFactor(String value) {
  final normalized = _normalizedFactorText(value);
  return normalized.startsWith('ausencia ') ||
      normalized.startsWith('ausencia de') ||
      normalized.startsWith('sem ') ||
      normalized.contains('ausencia de') ||
      normalized.contains('nao ha sinais') ||
      normalized.contains('nao foram relatad') ||
      normalized.contains('curta duracao') ||
      normalized.contains('baixa especificidade');
}

class _FactorBuckets {
  const _FactorBuckets({
    required this.increasing,
    required this.limiting,
    required this.reassuring,
  });

  final List<String> increasing;
  final List<String> limiting;
  final List<String> reassuring;
}

_FactorBuckets _classifyRiskFactors({
  required List<String> increasingCandidates,
  required List<String> limitingCandidates,
  required List<String> reassuringCandidates,
}) {
  final increasing = <String>[];
  final limiting = <String>[...limitingCandidates];
  final reassuring = <String>[...reassuringCandidates];

  for (final factor in increasingCandidates) {
    if (_looksLikeConfidenceLimitation(factor)) {
      limiting.add(factor);
    } else if (_looksLikeReassuringFactor(factor)) {
      reassuring.add(factor);
    } else {
      increasing.add(factor);
    }
  }

  return _FactorBuckets(
    increasing: _distinctStrings(increasing),
    limiting: _distinctStrings(limiting),
    reassuring: _distinctStrings(reassuring),
  );
}

bool _parseBool(dynamic raw) {
  return switch (raw) {
    bool value => value,
    String value => value.trim().toLowerCase() == 'true',
    num value => value != 0,
    _ => false,
  };
}

const int _maxProtocolRegions = 2;
// Each region requires overview, medium, and close shots before analysis.
const int _requiredShotsPerRegion = 3;
// Offline Gemma 4 accepts only a small multimodal context window per request,
// so the capture flow is capped at two regions and six total photos.
const int _maxAnalysisImages = 6;
// Scripts and the Android bridge both converge on this app-scoped location
// when deciding where the .litertlm artifact should live on the device.
const String _defaultModelPath =
    '/storage/emulated/0/Android/data/com.example.hansen_guard/files/gemma-4-E2B-it.litertlm';

class SkinCase {
  const SkinCase({
    required this.name,
    required this.assetPath,
    required this.region,
    required this.visualSummary,
    String? englishName,
    String? englishRegion,
    String? englishVisualSummary,
  }) : englishName = englishName ?? name,
       englishRegion = englishRegion ?? region,
       englishVisualSummary = englishVisualSummary ?? visualSummary;

  final String name;
  final String assetPath;
  final String region;
  final String visualSummary;
  final String englishName;
  final String englishRegion;
  final String englishVisualSummary;

  String nameFor(AppLanguage language) => language.pick(name, englishName);

  String regionFor(AppLanguage language) =>
      language.pick(region, englishRegion);

  String visualSummaryFor(AppLanguage language) =>
      language.pick(visualSummary, englishVisualSummary);
}

/// Payload assembled in Flutter and forwarded to the native Gemma 4 bridge.
///
/// The Android side receives the photo protocol, local quality hints, and the
/// questionnaire answers together so the model can reason over one coherent
/// offline triage request.
class TriageInput {
  const TriageInput({
    required this.language,
    required this.caseName,
    required this.region,
    required this.visualSummary,
    required this.imageBytesList,
    required this.imageLabels,
    required this.imageQualityNotes,
    required this.hasNumbness,
    required this.changedColor,
    required this.hasContactWithConfirmedCase,
    required this.hasNervePainOrShock,
    required this.hasMuscleWeakness,
    required this.hasDrynessOrHairLoss,
    required this.hasMultipleLesions,
    required this.hasWoundOrBurnWithoutPain,
    required this.notes,
    required this.duration,
  });

  final AppLanguage language;
  final String caseName;
  final String region;
  final String visualSummary;
  final List<Uint8List> imageBytesList;
  final List<String> imageLabels;
  final List<String> imageQualityNotes;
  final bool hasNumbness;
  final bool changedColor;
  final bool hasContactWithConfirmedCase;
  final bool hasNervePainOrShock;
  final bool hasMuscleWeakness;
  final bool hasDrynessOrHairLoss;
  final bool hasMultipleLesions;
  final bool hasWoundOrBurnWithoutPain;
  final String notes;
  final DurationOption duration;
}

enum ImageInputMode { sample, camera, gallery }

enum CaptureShotType {
  overview(
    'Foto geral',
    'Mostre a regiao do corpo e a posicao da mancha no contexto anatomico.',
    Icons.crop_free_outlined,
  ),
  medium(
    'Foto media',
    'Aproxime para mostrar bordas, distribuicao e relacao com a pele ao redor.',
    Icons.center_focus_strong_outlined,
  ),
  close(
    'Foto proxima',
    'Capture detalhes de textura, cor e limite da lesao sem usar zoom digital.',
    Icons.zoom_in_map_outlined,
  ),
  adjacent(
    'Comparacao com pele adjacente',
    'Opcional: inclua pele aparentemente saudavel ao lado da mancha.',
    Icons.compare_outlined,
  );

  const CaptureShotType(this.label, this.instruction, this.icon);

  final String label;
  final String instruction;
  final IconData icon;

  bool get isRequired => this != CaptureShotType.adjacent;
}

extension CaptureShotTypeLocalization on CaptureShotType {
  String labelFor(AppLanguage language) {
    return switch (this) {
      CaptureShotType.overview => language.pick('Foto geral', 'Overview photo'),
      CaptureShotType.medium => language.pick('Foto media', 'Medium photo'),
      CaptureShotType.close => language.pick('Foto proxima', 'Close photo'),
      CaptureShotType.adjacent => language.pick(
        'Comparacao com pele adjacente',
        'Adjacent skin comparison',
      ),
    };
  }

  String instructionFor(AppLanguage language) {
    return switch (this) {
      CaptureShotType.overview => language.pick(
        'Mostre a regiao do corpo e a posicao da mancha no contexto anatomico.',
        'Show the body region and where the patch sits in the anatomical context.',
      ),
      CaptureShotType.medium => language.pick(
        'Aproxime para mostrar bordas, distribuicao e relacao com a pele ao redor.',
        'Move closer to show borders, distribution, and relation to nearby skin.',
      ),
      CaptureShotType.close => language.pick(
        'Capture detalhes de textura, cor e limite da lesao sem usar zoom digital.',
        'Capture texture, color, and lesion margins without digital zoom.',
      ),
      CaptureShotType.adjacent => language.pick(
        'Opcional: inclua pele aparentemente saudavel ao lado da mancha.',
        'Optional: include apparently healthy skin next to the lesion.',
      ),
    };
  }
}

class PhotoQualityReport {
  const PhotoQualityReport({
    required this.width,
    required this.height,
    required this.averageLuma,
    required this.contrast,
    required this.sharpness,
    required this.warnings,
  });

  final int width;
  final int height;
  final double averageLuma;
  final double contrast;
  final double sharpness;
  final List<String> warnings;

  bool get isAcceptable => warnings.isEmpty || isNotEvaluated;
  bool get isNotEvaluated =>
      width == 0 &&
      height == 0 &&
      warnings.length == 1 &&
      warnings.single == 'qualidade nao avaliada';

  String get statusLabel => statusLabelFor(AppLanguage.portuguese);

  String statusLabelFor(AppLanguage language) {
    if (isNotEvaluated) {
      return language.pick('Imagem ilustrativa', 'Illustrative image');
    }

    return isAcceptable
        ? language.pick('Qualidade adequada', 'Quality looks good')
        : language.pick('Revisar foto', 'Review photo');
  }

  List<String> localizedWarningsFor(AppLanguage language) {
    return warnings
        .map((warning) => _localizedQualityWarning(warning, language))
        .toList(growable: false);
  }

  String get promptSummary => promptSummaryFor(AppLanguage.portuguese);

  String promptSummaryFor(AppLanguage language) {
    if (isNotEvaluated) {
      return language.pick('imagem ilustrativa', 'illustrative image');
    }

    if (warnings.isEmpty) {
      return language.pick(
        'qualidade tecnica adequada',
        'technical quality acceptable',
      );
    }

    return language.pick(
      'alertas locais: ${localizedWarningsFor(language).join('; ')}',
      'local alerts: ${localizedWarningsFor(language).join('; ')}',
    );
  }

  static const notEvaluated = PhotoQualityReport(
    width: 0,
    height: 0,
    averageLuma: 0,
    contrast: 0,
    sharpness: 0,
    warnings: ['qualidade nao avaliada'],
  );
}

class SelectedTriageImage {
  const SelectedTriageImage({
    required this.label,
    required this.bytes,
    required this.sourceMode,
    required this.regionIndex,
    required this.shotType,
    required this.quality,
  });

  final String label;
  final Uint8List bytes;
  final ImageInputMode sourceMode;
  final int regionIndex;
  final CaptureShotType shotType;
  final PhotoQualityReport quality;

  String get protocolLabel => protocolLabelFor(AppLanguage.portuguese);

  String protocolLabelFor(AppLanguage language) {
    return language.pick(
      'Regiao $regionIndex - ${shotType.labelFor(language)}',
      'Region $regionIndex - ${shotType.labelFor(language)}',
    );
  }

  String get analysisLabel => analysisLabelFor(AppLanguage.portuguese);

  String analysisLabelFor(AppLanguage language) =>
      '${protocolLabelFor(language)} ($label)';
}

enum PatientSex {
  female('Feminino', 'feminino'),
  male('Masculino', 'masculino'),
  other('Outro', 'outro');

  const PatientSex(this.label, this.wireValue);

  final String label;
  final String wireValue;
}

extension PatientSexLocalization on PatientSex {
  String labelFor(AppLanguage language) {
    return switch (this) {
      PatientSex.female => language.pick('Feminino', 'Female'),
      PatientSex.male => language.pick('Masculino', 'Male'),
      PatientSex.other => language.pick('Outro', 'Other'),
    };
  }
}

enum _AppTab {
  home(Icons.home_outlined, Icons.home_rounded),
  newCase(Icons.add_circle_outline, Icons.add_circle_rounded),
  history(Icons.history_outlined, Icons.history_rounded),
  settings(Icons.settings_outlined, Icons.settings_rounded);

  const _AppTab(this.icon, this.activeIcon);

  final IconData icon;
  final IconData activeIcon;
}

enum AppLanguage {
  portuguese('pt', 'Português', 'Ver em português'),
  english('en', 'English', 'View in English');

  const AppLanguage(this.code, this.label, this.actionLabel);

  final String code;
  final String label;
  final String actionLabel;

  bool get isEnglish => this == AppLanguage.english;

  String pick(String portuguese, String english) {
    return isEnglish ? english : portuguese;
  }
}

extension _AppTabLocalization on _AppTab {
  String labelFor(AppLanguage language) {
    return switch (this) {
      _AppTab.home => language.pick('Inicio', 'Home'),
      _AppTab.newCase => language.pick('Novo Caso', 'New Case'),
      _AppTab.history => language.pick('Historico', 'History'),
      _AppTab.settings => language.pick('Config', 'Settings'),
    };
  }
}

class AppLanguageScope extends InheritedWidget {
  const AppLanguageScope({
    super.key,
    required this.language,
    required super.child,
  });

  final AppLanguage language;

  static AppLanguage of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AppLanguageScope>();
    return scope?.language ?? AppLanguage.portuguese;
  }

  @override
  bool updateShouldNotify(AppLanguageScope oldWidget) {
    return oldWidget.language != language;
  }
}

class PatientProfile {
  const PatientProfile({
    required this.name,
    required this.sex,
    required this.age,
  });

  final String name;
  final PatientSex sex;
  final int age;

  String get summaryLabel => '$name, $age anos, ${sex.label.toLowerCase()}';

  String summaryLabelFor(AppLanguage language) {
    return language.pick(
      '$name, $age anos, ${sex.labelFor(language).toLowerCase()}',
      '$name, $age years old, ${sex.labelFor(language).toLowerCase()}',
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'sex': sex.wireValue,
    'age': age,
  };

  factory PatientProfile.fromJson(Map<String, dynamic> json) {
    return PatientProfile(
      name: (json['name'] ?? '').toString(),
      sex: switch ((json['sex'] ?? '').toString().toLowerCase()) {
        'feminino' || 'female' => PatientSex.female,
        'masculino' || 'male' => PatientSex.male,
        _ => PatientSex.other,
      },
      age: int.tryParse((json['age'] ?? '').toString()) ?? 0,
    );
  }
}

class SavedCaseRecord {
  const SavedCaseRecord({
    required this.id,
    required this.patient,
    required this.createdAt,
    required this.caseName,
    required this.imagePaths,
    required this.result,
  });

  final String id;
  final PatientProfile patient;
  final DateTime createdAt;
  final String caseName;
  final List<String> imagePaths;
  final TriageResult result;

  Map<String, dynamic> toJson() => {
    'id': id,
    'patient': patient.toJson(),
    'createdAt': createdAt.toIso8601String(),
    'caseName': caseName,
    'imagePaths': imagePaths,
    'result': {
      'score': result.score,
      'riskLevel': result.level.name,
      'imageQualitySummary': result.imageQualitySummary,
      'regionFindings': result.regionFindings
          .map((finding) => finding.toJson())
          .toList(),
      'visualFindings': result.visualFindings,
      'visualRiskScore': result.visualRiskScore,
      'visualRiskLevel': result.visualRiskLevel.name,
      'clinicalNeuralRiskScore': result.clinicalNeuralRiskScore,
      'clinicalNeuralRiskLevel': result.clinicalNeuralRiskLevel.name,
      'relevantSymptoms': result.relevantSymptoms,
      'riskFactors': result.riskFactors,
      'riskIncreasingFactors': result.riskFactors,
      'confidenceLimitingFactors': result.confidenceLimitingFactors,
      'reassuringFactors': result.reassuringFactors,
      'reasoning': result.reasoning,
      'referralReason': result.referralReason,
      'nextAction': result.nextAction,
      'recommendedAction': result.recommendedAction,
      'consistencyNote': result.consistencyNote,
      'scoreAdjusted': result.scoreAdjusted,
    },
  };

  factory SavedCaseRecord.fromJson(Map<String, dynamic> json) {
    final patientData = json['patient'] is Map
        ? Map<String, dynamic>.from(json['patient'] as Map)
        : <String, dynamic>{};
    final resultData = json['result'] is Map
        ? Map<String, dynamic>.from(json['result'] as Map)
        : <String, dynamic>{};

    return SavedCaseRecord(
      id: (json['id'] ?? '').toString(),
      patient: PatientProfile.fromJson(patientData),
      createdAt:
          DateTime.tryParse((json['createdAt'] ?? '').toString()) ??
          DateTime.now(),
      caseName: (json['caseName'] ?? '').toString(),
      imagePaths: _parseStringList(json['imagePaths']),
      result: TriageResult.fromMap(resultData),
    );
  }

  String get displayTitle => displayTitleFor(AppLanguage.portuguese);
  String get subtitle => subtitleFor(AppLanguage.portuguese);

  String displayTitleFor(AppLanguage language) =>
      '${patient.name} · ${result.level.labelFor(language)}';

  String subtitleFor(AppLanguage language) => language.pick(
    '${patient.age} anos · ${patient.sex.labelFor(language)} · ${result.score}/100',
    '${patient.age} years · ${patient.sex.labelFor(language)} · ${result.score}/100',
  );
}

class LocalCaseRepository {
  Future<Directory> _rootDirectory() async {
    try {
      return await getApplicationDocumentsDirectory();
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  Future<Directory> _storageDirectory() async {
    final root = await _rootDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}hansen_guard_history',
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<File> _recordsFile() async {
    final directory = await _storageDirectory();
    return File('${directory.path}${Platform.pathSeparator}records.json');
  }

  Future<List<SavedCaseRecord>> loadCases() async {
    final file = await _recordsFile();
    if (!await file.exists()) {
      return const <SavedCaseRecord>[];
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) {
        return const <SavedCaseRecord>[];
      }

      final records = <SavedCaseRecord>[];
      for (final item in decoded) {
        if (item is Map) {
          records.add(SavedCaseRecord.fromJson(item.cast<String, dynamic>()));
        }
      }
      records.sort((left, right) => right.createdAt.compareTo(left.createdAt));
      return records;
    } catch (_) {
      return const <SavedCaseRecord>[];
    }
  }

  Future<SavedCaseRecord> saveCase({
    required PatientProfile patient,
    required String caseName,
    required List<Uint8List> imageBytesList,
    required TriageResult result,
  }) async {
    final storageRoot = await _storageDirectory();
    final recordId = DateTime.now().microsecondsSinceEpoch.toString();
    final caseDirectory = Directory(
      '${storageRoot.path}${Platform.pathSeparator}$recordId',
    );
    await caseDirectory.create(recursive: true);

    final imagePaths = <String>[];
    for (var index = 0; index < imageBytesList.length; index++) {
      final file = File(
        '${caseDirectory.path}${Platform.pathSeparator}image_${index + 1}.jpg',
      );
      await file.writeAsBytes(imageBytesList[index], flush: true);
      imagePaths.add(file.path);
    }

    final record = SavedCaseRecord(
      id: recordId,
      patient: patient,
      createdAt: DateTime.now(),
      caseName: caseName,
      imagePaths: imagePaths,
      result: result,
    );

    final recordsFile = await _recordsFile();
    final currentRecords = await loadCases();
    final updatedRecords = [record, ...currentRecords];
    await recordsFile.writeAsString(
      jsonEncode(updatedRecords.map((item) => item.toJson()).toList()),
      flush: true,
    );

    return record;
  }

  Future<void> deleteCase(String recordId) async {
    final recordsFile = await _recordsFile();
    final currentRecords = await loadCases();
    final updatedRecords = currentRecords
        .where((record) => record.id != recordId)
        .toList(growable: false);

    await recordsFile.writeAsString(
      jsonEncode(updatedRecords.map((item) => item.toJson()).toList()),
      flush: true,
    );

    final storageRoot = await _storageDirectory();
    final caseDirectory = Directory(
      '${storageRoot.path}${Platform.pathSeparator}$recordId',
    );
    if (await caseDirectory.exists()) {
      await caseDirectory.delete(recursive: true);
    }
  }
}

class RegionFinding {
  const RegionFinding({
    required this.region,
    required this.imageQuality,
    required this.findings,
  });

  final String region;
  final String imageQuality;
  final List<String> findings;

  Map<String, dynamic> toJson() => {
    'region': region,
    'imageQuality': imageQuality,
    'findings': findings,
  };

  factory RegionFinding.fromMap(Map<dynamic, dynamic> map) {
    final rawImageQuality = (map['imageQuality'] ?? map['image_quality'] ?? '')
        .toString()
        .trim();
    final findings = _sanitizeAnalysisList(
      _parseStringList(map['findings']),
      stripLeadingRegionLabel: true,
    );
    final qualityFinding = _findingTextFromImageQuality(rawImageQuality);
    final cleanedImageQuality = _cleanRegionImageQuality(rawImageQuality);
    return RegionFinding(
      region: _sanitizeAnalysisText(
        (map['region'] ?? map['region_label'] ?? '').toString().trim(),
      ),
      imageQuality: cleanedImageQuality == 'boa' ? '' : cleanedImageQuality,
      findings: qualityFinding == null
          ? findings
          : _sanitizeAnalysisList([
              qualityFinding,
              ...findings,
            ], stripLeadingRegionLabel: true),
    );
  }
}

class TriageResult {
  const TriageResult({
    required this.score,
    required this.level,
    required this.visualFindings,
    required this.reasoning,
    required this.recommendedAction,
    required this.consistencyNote,
    required this.scoreAdjusted,
    this.imageQualitySummary = const <String>[],
    this.regionFindings = const <RegionFinding>[],
    this.relevantSymptoms = const <String>[],
    this.riskFactors = const <String>[],
    this.confidenceLimitingFactors = const <String>[],
    this.reassuringFactors = const <String>[],
    int? visualRiskScore,
    RiskLevel? visualRiskLevel,
    int? clinicalNeuralRiskScore,
    RiskLevel? clinicalNeuralRiskLevel,
    this.referralReason = '',
    String? nextAction,
  }) : visualRiskScore = visualRiskScore ?? score,
       visualRiskLevel = visualRiskLevel ?? level,
       clinicalNeuralRiskScore = clinicalNeuralRiskScore ?? score,
       clinicalNeuralRiskLevel = clinicalNeuralRiskLevel ?? level,
       nextAction = nextAction ?? recommendedAction;

  final int score;
  final RiskLevel level;
  final List<String> imageQualitySummary;
  final List<RegionFinding> regionFindings;
  final List<String> visualFindings;
  final int visualRiskScore;
  final RiskLevel visualRiskLevel;
  final int clinicalNeuralRiskScore;
  final RiskLevel clinicalNeuralRiskLevel;
  final List<String> relevantSymptoms;
  final List<String> riskFactors;
  final List<String> confidenceLimitingFactors;
  final List<String> reassuringFactors;
  final List<String> reasoning;
  final String referralReason;
  final String nextAction;
  final String recommendedAction;
  final String? consistencyNote;
  final bool scoreAdjusted;

  factory TriageResult.fromMap(
    Map<dynamic, dynamic> map, {
    AppLanguage language = AppLanguage.portuguese,
  }) {
    final rawScore = map['score'];
    final parsedScore = switch (rawScore) {
      int value => value,
      double value => value.round(),
      String value => int.tryParse(value) ?? 0,
      _ => 0,
    };
    final score = parsedScore.clamp(0, 100);

    final visualFindings = _sanitizeAnalysisList(
      _parseStringList(map['visualFindings'] ?? map['visual_findings']),
      stripLeadingRegionLabel: true,
    );
    final imageQualitySummary = _sanitizeAnalysisList(
      _parseStringList(
        map['imageQualitySummary'] ?? map['image_quality_summary'],
      ),
      dropPositiveQuality: true,
    );
    final regionFindings = _parseRegionFindings(
      map['regionFindings'] ?? map['region_findings'],
      fallbackFindings: visualFindings,
      fallbackImageQuality: imageQualitySummary,
      language: language,
    );
    final visualRiskScore = _parseScore(
      map['visualRiskScore'] ?? map['visual_risk_score'],
      fallback: score,
    );
    final clinicalNeuralRiskScore = _parseScore(
      map['clinicalNeuralRiskScore'] ??
          map['clinical_neural_risk_score'] ??
          map['clinicalRiskScore'] ??
          map['clinical_risk_score'],
      fallback: score,
    );
    final visualRiskLevel = riskLevelFromWire(
      (map['visualRiskLevel'] ?? map['visual_risk_level'] ?? '').toString(),
      fallbackScore: visualRiskScore,
    );
    final clinicalNeuralRiskLevel = riskLevelFromWire(
      (map['clinicalNeuralRiskLevel'] ??
              map['clinical_neural_risk_level'] ??
              map['clinicalRiskLevel'] ??
              map['clinical_risk_level'] ??
              '')
          .toString(),
      fallbackScore: clinicalNeuralRiskScore,
    );
    final relevantSymptoms = _sanitizeAnalysisList(
      _parseStringList(map['relevantSymptoms'] ?? map['relevant_symptoms']),
    );
    final factorBuckets = _classifyRiskFactors(
      increasingCandidates: _sanitizeAnalysisList(
        _parseStringList(
          map['riskIncreasingFactors'] ??
              map['risk_increasing_factors'] ??
              map['riskFactors'] ??
              map['risk_factors'] ??
              map['elevatingFactors'],
        ),
      ),
      limitingCandidates: _sanitizeAnalysisList(
        _parseStringList(
          map['confidenceLimitingFactors'] ??
              map['confidence_limiting_factors'] ??
              map['limitingFactors'] ??
              map['limiting_factors'],
        ),
      ),
      reassuringCandidates: _sanitizeAnalysisList(
        _parseStringList(
          map['reassuringFactors'] ??
              map['reassuring_factors'] ??
              map['protectiveFactors'] ??
              map['protective_factors'],
        ),
      ),
    );
    final reasoning = _sanitizeAnalysisList(_parseStringList(map['reasoning']));

    final recommendedAction = _sanitizeAnalysisText(
      (map['recommendedAction'] ?? map['recommended_action'] ?? '')
          .toString()
          .trim(),
    );
    final nextAction = _sanitizeAnalysisText(
      (map['nextAction'] ?? map['next_action'] ?? recommendedAction)
          .toString()
          .trim(),
    );
    final referralReason = _sanitizeAnalysisText(
      (map['referralReason'] ?? map['referral_reason'] ?? '').toString().trim(),
    );
    final rawLevel = (map['riskLevel'] ?? map['risk_level'] ?? '').toString();
    final consistencyNote = _sanitizeAnalysisText(
      (map['consistencyNote'] ?? map['consistency_note'] ?? '')
          .toString()
          .trim(),
    );
    final scoreAdjusted = _parseBool(
      map['scoreAdjusted'] ?? map['score_adjusted'],
    );

    return TriageResult(
      score: score,
      level: riskLevelFromWire(rawLevel, fallbackScore: score),
      imageQualitySummary: imageQualitySummary,
      regionFindings: regionFindings,
      visualFindings: visualFindings,
      visualRiskScore: visualRiskScore,
      visualRiskLevel: visualRiskLevel,
      clinicalNeuralRiskScore: clinicalNeuralRiskScore,
      clinicalNeuralRiskLevel: clinicalNeuralRiskLevel,
      relevantSymptoms: relevantSymptoms,
      riskFactors: factorBuckets.increasing,
      confidenceLimitingFactors: factorBuckets.limiting,
      reassuringFactors: factorBuckets.reassuring,
      reasoning: reasoning.isEmpty
          ? <String>[
              language.pick(
                'O modelo nao retornou justificativas estruturadas para esta analise.',
                'The model did not return structured reasoning for this analysis.',
              ),
            ]
          : reasoning,
      referralReason: referralReason.isEmpty
          ? language.pick(
              'Prioridade definida pela combinacao entre achados visuais, sintomas informados e fatores de risco.',
              'Priority defined by the combination of visual findings, reported symptoms, and risk factors.',
            )
          : referralReason,
      nextAction: nextAction.isEmpty
          ? language.pick(
              'Encaminhar para avaliacao clinica presencial se houver persistencia da lesao, dormencia ou piora do quadro.',
              'Refer for in-person clinical evaluation if the lesion persists, numbness is present, or the condition worsens.',
            )
          : nextAction,
      recommendedAction: recommendedAction.isEmpty
          ? language.pick(
              'Encaminhar para avaliacao clinica presencial se houver persistencia da lesao, dormencia ou piora do quadro.',
              'Refer for in-person clinical evaluation if the lesion persists, numbness is present, or the condition worsens.',
            )
          : recommendedAction,
      consistencyNote: consistencyNote.isEmpty ? null : consistencyNote,
      scoreAdjusted: scoreAdjusted,
    );
  }

  static int _parseScore(dynamic raw, {required int fallback}) {
    final parsed = switch (raw) {
      int value => value,
      double value => value.round(),
      String value => int.tryParse(value),
      _ => null,
    };
    return (parsed ?? fallback).clamp(0, 100);
  }

  static List<RegionFinding> _parseRegionFindings(
    dynamic raw, {
    required List<String> fallbackFindings,
    required List<String> fallbackImageQuality,
    required AppLanguage language,
  }) {
    if (raw is List) {
      final findings = <RegionFinding>[];
      for (final item in raw) {
        if (item is Map) {
          final finding = RegionFinding.fromMap(item);
          if (finding.region.isNotEmpty ||
              finding.findings.isNotEmpty ||
              finding.imageQuality.isNotEmpty) {
            findings.add(finding);
          }
        }
      }
      if (findings.isNotEmpty) {
        return findings;
      }
    }

    if (fallbackFindings.isEmpty) {
      return const <RegionFinding>[];
    }

    return [
      RegionFinding(
        region: language.pick('Regiao avaliada', 'Assessed region'),
        imageQuality: fallbackImageQuality.isEmpty
            ? language.pick(
                'Qualidade da imagem nao informada.',
                'Image quality was not provided.',
              )
            : fallbackImageQuality.join(' '),
        findings: fallbackFindings,
      ),
    ];
  }
}

class ModelInitializationResult {
  const ModelInitializationResult({
    required this.modelPath,
    required this.backend,
    required this.message,
  });

  final String modelPath;
  final String backend;
  final String message;

  factory ModelInitializationResult.fromMap(Map<dynamic, dynamic> map) {
    return ModelInitializationResult(
      modelPath: (map['modelPath'] ?? '').toString(),
      backend: (map['backend'] ?? '').toString(),
      message: (map['message'] ?? '').toString(),
    );
  }
}

/// Thin Flutter-side adapter around the native Android LiteRT-LM pipeline.
///
/// Flutter stays responsible for capture UX and presentation. Android owns the
/// long-lived Gemma engine, prompt construction, JSON repair, and guardrails.
class LiteRtTriageEngine {
  const LiteRtTriageEngine();

  // Must match the MethodChannel registered by MainActivity on Android.
  static const MethodChannel _channel = MethodChannel(
    'com.example.hansen_guard/litert_lm',
  );

  // LiteRT-LM is only wired on native Android builds in this prototype.
  bool get supportsNativeChannel =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Ask Android for the canonical app-specific path where the model should be
  /// stored, instead of relying on a hardcoded path from Flutter alone.
  Future<String?> getRecommendedModelPath() async {
    if (!supportsNativeChannel) {
      return null;
    }

    return _channel.invokeMethod<String>('getRecommendedModelPath');
  }

  /// Initialize or reload the on-device Gemma 4 engine with the requested
  /// backend. Android may fall back from GPU to CPU when needed.
  Future<ModelInitializationResult> initializeModel({
    required String modelPath,
    required LiteRtBackend backend,
    AppLanguage language = AppLanguage.portuguese,
  }) async {
    final response = await _channel
        .invokeMapMethod<String, dynamic>('initializeModel', {
          'modelPath': modelPath,
          'backend': backend.wireValue,
          'languageCode': language.code,
        });

    if (response == null) {
      throw StateError(
        language == AppLanguage.english
            ? 'LiteRT-LM initialization returned no data.'
            : 'A inicializacao do LiteRT-LM nao retornou dados.',
      );
    }

    return ModelInitializationResult.fromMap(response);
  }

  /// Submit the full multimodal triage payload. The native side turns this into
  /// a prompt, runs Gemma 4, repairs malformed JSON if needed, and applies
  /// deterministic clinical guardrails before returning a structured result.
  Future<TriageResult> analyze(TriageInput input) async {
    final response = await _channel
        .invokeMapMethod<String, dynamic>('analyzeTriage', {
          // Kept for backward compatibility; the native path prefers the full
          // imageBytesList when present.
          'imageBytes': input.imageBytesList.first,
          'imageBytesList': input.imageBytesList,
          'imageLabels': input.imageLabels,
          'imageQualityNotes': input.imageQualityNotes,
          'languageCode': input.language.code,
          'caseName': input.caseName,
          'region': input.region,
          'visualSummary': input.visualSummary,
          'hasNumbness': input.hasNumbness,
          'changedColor': input.changedColor,
          'hasContactWithConfirmedCase': input.hasContactWithConfirmedCase,
          'hasNervePainOrShock': input.hasNervePainOrShock,
          'hasMuscleWeakness': input.hasMuscleWeakness,
          'hasDrynessOrHairLoss': input.hasDrynessOrHairLoss,
          'hasMultipleLesions': input.hasMultipleLesions,
          'hasWoundOrBurnWithoutPain': input.hasWoundOrBurnWithoutPain,
          'notes': input.notes,
          'durationLabel': input.duration.labelFor(input.language),
          'durationKey': input.duration.name,
        });

    if (response == null) {
      throw StateError(
        input.language == AppLanguage.english
            ? 'Gemma 4 analysis returned no data.'
            : 'A analise do Gemma 4 nao retornou dados.',
      );
    }

    return TriageResult.fromMap(response, language: input.language);
  }

  /// Release the native engine when the screen goes away so the next session
  /// can rebuild it with a clean backend/model configuration if required.
  Future<void> disposeModel() async {
    if (!supportsNativeChannel) {
      return;
    }

    await _channel.invokeMethod<void>('disposeModel');
  }
}

const _cases = [
  SkinCase(
    name: 'Caso 01',
    englishName: 'Case 01',
    assetPath: 'assets/cases/hanseniase_01.jpeg',
    region: 'Imagem local',
    englishRegion: 'Local image',
    visualSummary: 'mancha cutanea delimitada em area exposta',
    englishVisualSummary: 'well-defined skin patch in an exposed area',
  ),
  SkinCase(
    name: 'Caso 02',
    englishName: 'Case 02',
    assetPath: 'assets/cases/hanseniase_02.jpeg',
    region: 'Imagem local',
    englishRegion: 'Local image',
    visualSummary: 'area hipocromica ampla com bordas visiveis',
    englishVisualSummary: 'broad hypopigmented area with visible borders',
  ),
  SkinCase(
    name: 'Caso 03',
    englishName: 'Case 03',
    assetPath: 'assets/cases/hanseniase_03.jpeg',
    region: 'Imagem local',
    englishRegion: 'Local image',
    visualSummary: 'lesoes multiplas e alteracao de tonalidade da pele',
    englishVisualSummary: 'multiple lesions with skin tone variation',
  ),
  SkinCase(
    name: 'Caso 04',
    englishName: 'Case 04',
    assetPath: 'assets/cases/hanseniase_04.jpeg',
    region: 'Imagem local',
    englishRegion: 'Local image',
    visualSummary: 'imagem real de hanseniase para demonstracao offline',
    englishVisualSummary: 'real leprosy image for offline demonstration',
  ),
  SkinCase(
    name: 'Caso 05',
    englishName: 'Case 05',
    assetPath: 'assets/cases/hanseniase_05.jpeg',
    region: 'Imagem local',
    englishRegion: 'Local image',
    visualSummary: 'imagem real de hanseniase para demonstracao offline',
    englishVisualSummary: 'real leprosy image for offline demonstration',
  ),
  SkinCase(
    name: 'Caso 06',
    englishName: 'Case 06',
    assetPath: 'assets/cases/hanseniase_06.jpeg',
    region: 'Imagem local',
    englishRegion: 'Local image',
    visualSummary: 'imagem real de hanseniase para demonstracao offline',
    englishVisualSummary: 'real leprosy image for offline demonstration',
  ),
  SkinCase(
    name: 'Caso 07',
    englishName: 'Case 07',
    assetPath: 'assets/cases/hanseniase_07.jpeg',
    region: 'Imagem local',
    englishRegion: 'Local image',
    visualSummary: 'imagem real de hanseniase para demonstracao offline',
    englishVisualSummary: 'real leprosy image for offline demonstration',
  ),
  SkinCase(
    name: 'Caso 08',
    englishName: 'Case 08',
    assetPath: 'assets/cases/hanseniase_08.jpeg',
    region: 'Imagem local',
    englishRegion: 'Local image',
    visualSummary: 'imagem real de hanseniase para demonstracao offline',
    englishVisualSummary: 'real leprosy image for offline demonstration',
  ),
  SkinCase(
    name: 'Caso 09',
    englishName: 'Case 09',
    assetPath: 'assets/cases/hanseniase_09.jpeg',
    region: 'Imagem local',
    englishRegion: 'Local image',
    visualSummary: 'imagem real de hanseniase para demonstracao offline',
    englishVisualSummary: 'real leprosy image for offline demonstration',
  ),
  SkinCase(
    name: 'Caso 10',
    englishName: 'Case 10',
    assetPath: 'assets/cases/hanseniase_10.png',
    region: 'Imagem local',
    englishRegion: 'Local image',
    visualSummary: 'imagem real de hanseniase para demonstracao offline',
    englishVisualSummary: 'real leprosy image for offline demonstration',
  ),
  SkinCase(
    name: 'Caso 11',
    englishName: 'Case 11',
    assetPath: 'assets/cases/hanseniase_11.png',
    region: 'Imagem local',
    englishRegion: 'Local image',
    visualSummary: 'imagem real de hanseniase para demonstracao offline',
    englishVisualSummary: 'real leprosy image for offline demonstration',
  ),
  SkinCase(
    name: 'Caso 12',
    englishName: 'Case 12',
    assetPath: 'assets/cases/hanseniase_12.png',
    region: 'Imagem local',
    englishRegion: 'Local image',
    visualSummary: 'imagem real de hanseniase para demonstracao offline',
    englishVisualSummary: 'real leprosy image for offline demonstration',
  ),
  SkinCase(
    name: 'Caso 13',
    englishName: 'Case 13',
    assetPath: 'assets/cases/hanseniase_13.png',
    region: 'Imagem local',
    englishRegion: 'Local image',
    visualSummary: 'imagem real de hanseniase para demonstracao offline',
    englishVisualSummary: 'real leprosy image for offline demonstration',
  ),
];

class TriageScreen extends StatefulWidget {
  const TriageScreen({
    super.key,
    this.initialSavedCases = const <SavedCaseRecord>[],
  });

  final List<SavedCaseRecord> initialSavedCases;

  @override
  State<TriageScreen> createState() => _TriageScreenState();
}

/// Owns the patient workflow, local history, and the lifecycle of the on-device
/// Gemma 4 engine reused across analyses.
class _TriageScreenState extends State<TriageScreen> {
  final LiteRtTriageEngine _engine = const LiteRtTriageEngine();
  final LocalCaseRepository _caseRepository = LocalCaseRepository();
  final ImagePicker _imagePicker = ImagePicker();
  late final TextEditingController _notesController;
  late final TextEditingController _patientNameController;
  late final TextEditingController _patientAgeController;
  late final TextEditingController _historySearchController;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  PatientProfile? _activePatient;
  List<SelectedTriageImage> _customImages = const <SelectedTriageImage>[];
  int _selectedCustomImageIndex = 0;
  int _protocolRegionCount = 1;
  // Kept aligned with Android's recommended path so reload actions and helper
  // scripts target the same .litertlm location on device storage.
  String _recommendedModelPath = _defaultModelPath;
  DurationOption _duration = DurationOption.between3And12Months;
  // Prefer GPU first; the native bridge downgrades to CPU if GPU init fails.
  final LiteRtBackend _preferredBackend = LiteRtBackend.gpu;
  PatientSex _patientSex = PatientSex.other;
  bool _hasNumbness = false;
  bool _changedColor = true;
  bool _hasContactWithConfirmedCase = false;
  bool _hasNervePainOrShock = false;
  bool _hasMuscleWeakness = false;
  bool _hasDrynessOrHairLoss = false;
  bool _hasMultipleLesions = false;
  bool _hasWoundOrBurnWithoutPain = false;
  bool _isPickingImage = false;
  bool _isInitializing = false;
  bool _isAnalyzing = false;
  bool _isModelReady = false;
  bool _isLoadingCases = false;
  bool _showSplash = true;
  AppLanguage? _selectedLanguage;
  String? _errorMessage;
  List<SavedCaseRecord> _savedCases = const <SavedCaseRecord>[];
  TriageResult? _result;
  _AppTab _currentTab = _AppTab.home;
  int _triageStep = 0; // 0=patient, 1=photos, 2=questions, 3=analysis

  @override
  void initState() {
    super.initState();
    _notesController = TextEditingController();
    _patientNameController = TextEditingController();
    _patientAgeController = TextEditingController();
    _historySearchController = TextEditingController();
    _savedCases = widget.initialSavedCases;
    unawaited(_bootstrapModel());
    unawaited(_loadSavedCases());
    unawaited(_finishSplash());
  }

  @override
  void dispose() {
    unawaited(_engine.disposeModel());
    _notesController.dispose();
    _patientNameController.dispose();
    _patientAgeController.dispose();
    _historySearchController.dispose();
    super.dispose();
  }

  bool get _busy => _isInitializing || _isAnalyzing;
  bool get _hasCustomImages => _customImages.isNotEmpty;
  AppLanguage get _language => _selectedLanguage ?? AppLanguage.portuguese;
  String _t(String portuguese, String english) =>
      _language.pick(portuguese, english);
  bool get _canAddMoreImages =>
      !_busy && _customImages.length < _maxAnalysisImages;
  bool get _canAddProtocolRegion =>
      !_busy &&
      _protocolRegionCount < _maxProtocolRegions &&
      _customImages.length <= _maxAnalysisImages - _requiredShotsPerRegion;
  bool get _hasActivePatient => _activePatient != null;
  bool get _hasTriageDraft {
    return _customImages.isNotEmpty ||
        _result != null ||
        _notesController.text.trim().isNotEmpty ||
        _duration != DurationOption.between3And12Months ||
        _hasNumbness ||
        !_changedColor ||
        _hasContactWithConfirmedCase ||
        _hasNervePainOrShock ||
        _hasMuscleWeakness ||
        _hasDrynessOrHairLoss ||
        _hasMultipleLesions ||
        _hasWoundOrBurnWithoutPain;
  }

  List<SavedCaseRecord> get _visibleSavedCases {
    final query = _historySearchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      return _savedCases;
    }

    return _savedCases
        .where((record) {
          return record.patient.name.toLowerCase().contains(query);
        })
        .toList(growable: false);
  }

  Future<Uint8List> _loadAssetBytes(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<void> _finishSplash() async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) {
      return;
    }

    setState(() => _showSplash = false);
  }

  Future<void> _loadSavedCases() async {
    if (widget.initialSavedCases.isNotEmpty) {
      return;
    }

    setState(() => _isLoadingCases = true);

    try {
      final records = await _caseRepository.loadCases();
      if (!mounted) {
        return;
      }

      setState(() {
        _savedCases = records;
      });
    } catch (_) {
      // Keep startup resilient if the local history cannot be read.
    } finally {
      if (mounted) {
        setState(() => _isLoadingCases = false);
      }
    }
  }

  /// Resolve the app-scoped model path and warm the native engine during app
  /// startup so the first triage request does not also pay the init cost.
  Future<void> _bootstrapModel() async {
    final recommendedPath = await _resolveRecommendedModelPath();
    if (!mounted) {
      return;
    }

    setState(() {
      _recommendedModelPath = recommendedPath;
    });

    await _initializeModel(
      autoTriggered: true,
      modelPathOverride: recommendedPath,
    );
  }

  void _registerPatient() {
    final name = _patientNameController.text.trim();
    final age = int.tryParse(_patientAgeController.text.trim()) ?? 0;

    if (name.isEmpty) {
      _showMessage(
        _t('Informe o nome do paciente.', 'Enter the patient name.'),
      );
      return;
    }

    if (age <= 0 || age > 120) {
      _showMessage(
        _t(
          'Informe uma idade valida para o paciente.',
          'Enter a valid patient age.',
        ),
      );
      return;
    }

    setState(() {
      _activePatient = PatientProfile(name: name, sex: _patientSex, age: age);
      _customImages = const <SelectedTriageImage>[];
      _selectedCustomImageIndex = 0;
      _protocolRegionCount = 1;
      _result = null;
      _errorMessage = null;
      _triageStep = 1;
    });

    _showMessage(
      _t(
        'Paciente adicionado. Continue agora na triagem.',
        'Patient added. Continue to the triage flow now.',
      ),
    );
  }

  Future<void> _startNewPatient() async {
    if (_busy || _activePatient == null) {
      return;
    }

    final shouldContinue = await _confirmDestructiveAction(
      title: _t('Iniciar novo paciente?', 'Start a new patient?'),
      message: _hasTriageDraft
          ? _t(
              'O atendimento atual sera encerrado e as selecoes da triagem em andamento serao limpas. O historico salvo permanece disponivel.',
              'The current consultation will be closed and the ongoing triage selections will be cleared. Saved history will remain available.',
            )
          : _t(
              'Voce vai encerrar o paciente atual e voltar para o cadastro de um novo atendimento.',
              'You will close the current patient and return to the registration flow for a new consultation.',
            ),
      confirmLabel: _t('Novo paciente', 'New patient'),
    );
    if (!shouldContinue || !mounted) {
      return;
    }

    setState(() {
      _activePatient = null;
      _patientNameController.clear();
      _patientAgeController.clear();
      _patientSex = PatientSex.other;
      _customImages = const <SelectedTriageImage>[];
      _selectedCustomImageIndex = 0;
      _protocolRegionCount = 1;
      _duration = DurationOption.between3And12Months;
      _hasNumbness = false;
      _changedColor = true;
      _hasContactWithConfirmedCase = false;
      _hasNervePainOrShock = false;
      _hasMuscleWeakness = false;
      _hasDrynessOrHairLoss = false;
      _hasMultipleLesions = false;
      _hasWoundOrBurnWithoutPain = false;
      _notesController.clear();
      _result = null;
      _errorMessage = null;
      _triageStep = 0;
      _currentTab = _AppTab.newCase;
    });

    _showMessage(
      _t(
        'Cadastro liberado para um novo paciente.',
        'Registration is now ready for a new patient.',
      ),
    );
  }

  Future<bool> _confirmDestructiveAction({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_t('Cancelar', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );

    return confirmed ?? false;
  }

  void _selectTab(_AppTab tab) {
    if (_currentTab == tab) {
      return;
    }

    setState(() => _currentTab = tab);
  }

  void _goToTriageStep(int step) {
    setState(() => _triageStep = step);
  }

  Future<void> _deleteSavedCase(
    SavedCaseRecord record, {
    bool requiresConfirmation = true,
  }) async {
    if (requiresConfirmation) {
      final confirmed = await _confirmDestructiveAction(
        title: _t('Excluir do historico?', 'Delete from history?'),
        message: _t(
          'O registro de ${record.patient.name} e as imagens salvas desta analise serao removidos do dispositivo.',
          '${record.patient.name} and the saved images from this analysis will be removed from the device.',
        ),
        confirmLabel: _t('Excluir', 'Delete'),
      );
      if (!confirmed || !mounted) {
        return;
      }
    }

    final previousRecords = List<SavedCaseRecord>.from(_savedCases);

    setState(() {
      _savedCases = _savedCases
          .where((savedRecord) => savedRecord.id != record.id)
          .toList(growable: false);
    });

    try {
      await _caseRepository.deleteCase(record.id);

      if (!mounted) {
        return;
      }

      _showMessage(
        _t(
          'Registro removido do historico local.',
          'Record removed from local history.',
        ),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _savedCases = previousRecords;
      });

      _showMessage(
        _t(
          'Nao foi possivel excluir o registro selecionado.',
          'Could not delete the selected record.',
        ),
      );
    }
  }

  /// Ask Android for the current storage path instead of hardcoding OEM-specific
  /// external storage details in Flutter.
  Future<String> _resolveRecommendedModelPath() async {
    try {
      final recommendedPath = await _engine.getRecommendedModelPath();
      if (recommendedPath != null && recommendedPath.isNotEmpty) {
        return recommendedPath;
      }
    } catch (_) {
      // Fall back to the canonical app-scoped path when the native side is not
      // able to suggest a model location.
    }

    return _defaultModelPath;
  }

  /// Initialize the LiteRT-LM engine once per app session and reuse it for the
  /// rest of the patient flow.
  Future<void> _initializeModel({
    bool autoTriggered = false,
    String? modelPathOverride,
  }) async {
    if (_isInitializing) {
      return;
    }

    if (!_engine.supportsNativeChannel) {
      if (!autoTriggered) {
        _showMessage(
          _t(
            'O LiteRT-LM nativo so pode ser inicializado em Android fisico.',
            'Native LiteRT-LM can only be initialized on a physical Android device.',
          ),
        );
      }
      return;
    }

    final modelPath = (modelPathOverride ?? _recommendedModelPath).trim();
    if (modelPath.isEmpty) {
      if (!autoTriggered) {
        _showMessage(
          _t(
            'Informe o caminho absoluto do arquivo .litertlm no aparelho.',
            'Provide the absolute path to the .litertlm file on the device.',
          ),
        );
      }
      return;
    }

    setState(() {
      _isInitializing = true;
      _errorMessage = null;
      _result = null;
      _recommendedModelPath = modelPath;
    });

    try {
      await _engine.initializeModel(
        modelPath: modelPath,
        backend: _preferredBackend,
        language: _language,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _isModelReady = true;
        _errorMessage = null;
      });
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isModelReady = false;
        _errorMessage = error.message ?? error.code;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isModelReady = false;
        _errorMessage = '$error';
      });
    } finally {
      if (mounted) {
        setState(() => _isInitializing = false);
      }
    }
  }

  void _showImageLimitMessage() {
    _showMessage(
      _t(
        'Voce pode analisar ate $_maxAnalysisImages fotos por vez. Para duas regioes, use foto geral, media e proxima de cada regiao.',
        'You can analyze up to $_maxAnalysisImages photos at once. For two regions, use overview, medium, and close photos for each region.',
      ),
    );
  }

  void _addProtocolRegion() {
    if (!_canAddProtocolRegion) {
      _showMessage(
        _t(
          'Este protocolo aceita ate $_maxProtocolRegions regioes e $_maxAnalysisImages fotos por analise. Para avaliar duas regioes, remova a comparacao opcional e mantenha 3 fotos por regiao.',
          'This protocol supports up to $_maxProtocolRegions regions and $_maxAnalysisImages photos per analysis. To assess two regions, remove the optional comparison and keep 3 photos per region.',
        ),
      );
      return;
    }

    setState(() => _protocolRegionCount += 1);
    _showMessage(
      _t(
        'Regiao $_protocolRegionCount adicionada ao protocolo.',
        'Region $_protocolRegionCount added to the protocol.',
      ),
    );
  }

  Future<void> _captureProtocolPhoto(
    int regionIndex,
    CaptureShotType shotType,
  ) async {
    await _pickProtocolImage(
      source: ImageSource.camera,
      regionIndex: regionIndex,
      shotType: shotType,
    );
  }

  Future<void> _pickProtocolGalleryPhoto(
    int regionIndex,
    CaptureShotType shotType,
  ) async {
    await _pickProtocolImage(
      source: ImageSource.gallery,
      regionIndex: regionIndex,
      shotType: shotType,
    );
  }

  Future<void> _pickProtocolSampleImage(
    int regionIndex,
    CaptureShotType shotType,
    SkinCase skinCase,
  ) async {
    if (_isPickingImage || _busy) {
      return;
    }

    final existingIndex = _customImages.indexWhere(
      (image) => image.regionIndex == regionIndex && image.shotType == shotType,
    );
    if (existingIndex == -1 && !_canAddMoreImages) {
      _showImageLimitMessage();
      return;
    }

    setState(() {
      _isPickingImage = true;
      _errorMessage = null;
    });

    try {
      final bytes = await _loadAssetBytes(skinCase.assetPath);
      if (!mounted) {
        return;
      }

      final nextImage = SelectedTriageImage(
        label: _t(
          'exemplo ${skinCase.nameFor(_language)}',
          'sample ${skinCase.nameFor(_language)}',
        ),
        bytes: bytes,
        sourceMode: ImageInputMode.sample,
        regionIndex: regionIndex,
        shotType: shotType,
        quality: PhotoQualityReport.notEvaluated,
      );

      setState(() {
        final updatedImages = List<SelectedTriageImage>.from(_customImages);
        if (existingIndex == -1) {
          updatedImages.add(nextImage);
        } else {
          updatedImages[existingIndex] = nextImage;
        }
        updatedImages.sort(_compareProtocolImages);
        _customImages = updatedImages;
        _selectedCustomImageIndex = updatedImages.indexWhere(
          (image) =>
              image.regionIndex == regionIndex && image.shotType == shotType,
        );
        _result = null;
      });

      _showMessage(
        _t(
          '${nextImage.protocolLabelFor(_language)}: imagem de exemplo adicionada.',
          '${nextImage.protocolLabelFor(_language)}: sample image added.',
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorMessage = '$error';
      });
    } finally {
      if (mounted) {
        setState(() => _isPickingImage = false);
      }
    }
  }

  Future<void> _pickProtocolImage({
    required ImageSource source,
    required int regionIndex,
    required CaptureShotType shotType,
  }) async {
    if (_isPickingImage || _busy) {
      return;
    }

    final isCamera = source == ImageSource.camera;
    final existingIndex = _customImages.indexWhere(
      (image) => image.regionIndex == regionIndex && image.shotType == shotType,
    );
    if (existingIndex == -1 && !_canAddMoreImages) {
      _showImageLimitMessage();
      return;
    }

    setState(() {
      _isPickingImage = true;
      _errorMessage = null;
    });

    try {
      final photo = await _imagePicker.pickImage(
        source: source,
        imageQuality: 92,
        maxWidth: 1800,
      );

      if (photo == null) {
        if (!mounted) {
          return;
        }

        return;
      }

      final bytes = await photo.readAsBytes();
      if (!mounted) {
        return;
      }

      final quality = await _validatePhotoQuality(bytes);
      if (!mounted) {
        return;
      }

      final nextImage = SelectedTriageImage(
        label: isCamera ? 'camera' : photo.name,
        bytes: bytes,
        sourceMode: isCamera ? ImageInputMode.camera : ImageInputMode.gallery,
        regionIndex: regionIndex,
        shotType: shotType,
        quality: quality,
      );

      setState(() {
        final updatedImages = List<SelectedTriageImage>.from(_customImages);
        if (existingIndex == -1) {
          updatedImages.add(nextImage);
        } else {
          updatedImages[existingIndex] = nextImage;
        }
        updatedImages.sort(_compareProtocolImages);
        _customImages = updatedImages;
        _selectedCustomImageIndex = updatedImages.indexWhere(
          (image) =>
              image.regionIndex == regionIndex && image.shotType == shotType,
        );
        _result = null;
      });

      _showMessage(
        quality.isAcceptable
            ? _t(
                '${nextImage.protocolLabelFor(_language)}: qualidade adequada.',
                '${nextImage.protocolLabelFor(_language)}: quality looks good.',
              )
            : _t(
                '${nextImage.protocolLabelFor(_language)}: revise luz, foco ou enquadramento.',
                '${nextImage.protocolLabelFor(_language)}: review lighting, focus, or framing.',
              ),
      );
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorMessage = error.message ?? error.code;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorMessage = '$error';
      });
    } finally {
      if (mounted) {
        setState(() => _isPickingImage = false);
      }
    }
  }

  /// Compute lightweight quality heuristics locally. These warnings are shown
  /// in the UI and also appended to the Gemma prompt as confidence context.
  Future<PhotoQualityReport> _validatePhotoQuality(Uint8List bytes) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final originalWidth = descriptor.width;
      final originalHeight = descriptor.height;
      final targetWidth = math.min(320, originalWidth);
      codec = await descriptor.instantiateCodec(targetWidth: targetWidth);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      image.dispose();

      if (byteData == null) {
        return const PhotoQualityReport(
          width: 0,
          height: 0,
          averageLuma: 0,
          contrast: 0,
          sharpness: 0,
          warnings: ['nao foi possivel ler os pixels da imagem'],
        );
      }

      final width = image.width;
      final height = image.height;
      final raw = byteData.buffer.asUint8List();
      final pixelCount = width * height;
      final luminance = List<double>.filled(pixelCount, 0);
      var sum = 0.0;
      var sumSquares = 0.0;
      var darkPixels = 0;
      var brightPixels = 0;

      for (var pixel = 0; pixel < pixelCount; pixel++) {
        final offset = pixel * 4;
        final luma =
            0.2126 * raw[offset] +
            0.7152 * raw[offset + 1] +
            0.0722 * raw[offset + 2];
        luminance[pixel] = luma;
        sum += luma;
        sumSquares += luma * luma;
        if (luma < 45) {
          darkPixels += 1;
        } else if (luma > 235) {
          brightPixels += 1;
        }
      }

      final average = sum / pixelCount;
      final variance = math.max(
        0,
        (sumSquares / pixelCount) - average * average,
      );
      final contrast = math.sqrt(variance);
      final darkRatio = darkPixels / pixelCount;
      final brightRatio = brightPixels / pixelCount;

      var gradientSum = 0.0;
      var gradientCount = 0;
      for (var y = 1; y < height - 1; y += 2) {
        for (var x = 1; x < width - 1; x += 2) {
          final center = y * width + x;
          final gx = (luminance[center + 1] - luminance[center - 1]).abs();
          final gy = (luminance[center + width] - luminance[center - width])
              .abs();
          gradientSum += gx + gy;
          gradientCount += 1;
        }
      }
      final sharpness = gradientCount == 0 ? 0.0 : gradientSum / gradientCount;

      final warnings = <String>[];
      if (originalWidth < 800 || originalHeight < 600) {
        warnings.add('baixa resolucao');
      }
      if (average < 55 || darkRatio > 0.55) {
        warnings.add('pouca luz');
      }
      if (average > 210 || brightRatio > 0.35) {
        warnings.add('excesso de luz ou reflexo');
      }
      if (contrast < 28) {
        warnings.add('baixo contraste');
      }
      if (sharpness < 7) {
        warnings.add('possivel desfoque ou tremor');
      }
      if (darkRatio > 0.30 && brightRatio > 0.08) {
        warnings.add('sombra forte ou iluminacao irregular');
      }

      return PhotoQualityReport(
        width: originalWidth,
        height: originalHeight,
        averageLuma: average,
        contrast: contrast,
        sharpness: sharpness,
        warnings: warnings,
      );
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  int _compareProtocolImages(
    SelectedTriageImage left,
    SelectedTriageImage right,
  ) {
    final regionComparison = left.regionIndex.compareTo(right.regionIndex);
    if (regionComparison != 0) {
      return regionComparison;
    }

    return left.shotType.index.compareTo(right.shotType.index);
  }

  void _clearCustomImages() {
    setState(() {
      _customImages = const <SelectedTriageImage>[];
      _selectedCustomImageIndex = 0;
      _protocolRegionCount = 1;
      _result = null;
    });
  }

  void _deleteProtocolPhoto(int regionIndex, CaptureShotType shotType) {
    final imageIndex = _customImages.indexWhere(
      (image) => image.regionIndex == regionIndex && image.shotType == shotType,
    );
    if (imageIndex == -1) {
      return;
    }

    _deleteCustomImage(imageIndex);
  }

  void _deleteCustomImage(int index) {
    if (index < 0 || index >= _customImages.length) {
      return;
    }

    setState(() {
      final updatedImages = List<SelectedTriageImage>.from(_customImages)
        ..removeAt(index);
      _customImages = updatedImages;
      _selectedCustomImageIndex = updatedImages.isEmpty
          ? 0
          : _selectedCustomImageIndex
                .clamp(0, updatedImages.length - 1)
                .toInt();
      _result = null;
      _errorMessage = null;
    });
  }

  void _selectCustomImage(int index) {
    if (index < 0 || index >= _customImages.length) {
      return;
    }

    setState(() => _selectedCustomImageIndex = index);
  }

  /// Require the minimum photo set so Gemma compares each region with enough
  /// context before a triage request is sent.
  List<String> _missingRequiredProtocolShots() {
    if (_customImages.isEmpty) {
      return const <String>[];
    }

    final regions =
        _customImages.map((image) => image.regionIndex).toSet().toList()
          ..sort();
    final missing = <String>[];

    for (final regionIndex in regions) {
      for (final shotType in CaptureShotType.values.where(
        (shotType) => shotType.isRequired,
      )) {
        final hasShot = _customImages.any(
          (image) =>
              image.regionIndex == regionIndex && image.shotType == shotType,
        );
        if (!hasShot) {
          missing.add(
            _language.pick(
              'Regiao $regionIndex - ${shotType.labelFor(_language)}',
              'Region $regionIndex - ${shotType.labelFor(_language)}',
            ),
          );
        }
      }
    }

    return missing;
  }

  /// Package the photo protocol plus questionnaire into one multimodal request,
  /// then persist the structured result returned by the native Gemma pipeline.
  Future<void> _runAnalysis() async {
    final activePatient = _activePatient;
    if (activePatient == null) {
      _showMessage(
        _t(
          'Cadastre o paciente antes de iniciar a analise.',
          'Register the patient before starting the analysis.',
        ),
      );
      return;
    }

    if (!_isModelReady) {
      _showMessage(
        _t(
          'Os recursos offline ainda estao sendo preparados. Tente novamente em instantes.',
          'Offline resources are still being prepared. Try again shortly.',
        ),
      );
      return;
    }

    List<Uint8List> imageBytesList;
    List<String> imageLabels;
    List<String> imageQualityNotes;
    String caseName;
    String region;
    String visualSummary;

    if (!_hasCustomImages) {
      _showMessage(
        _t(
          'Tire uma foto, escolha uma imagem da galeria ou selecione uma imagem de exemplo no protocolo.',
          'Take a photo, choose one from the gallery, or select a sample image in the protocol.',
        ),
      );
      return;
    }

    final missingProtocolShots = _missingRequiredProtocolShots();
    if (missingProtocolShots.isNotEmpty) {
      _showMessage(
        _t(
          'Complete o protocolo antes de analisar: ${missingProtocolShots.join(', ')}.',
          'Complete the protocol before analyzing: ${missingProtocolShots.join(', ')}.',
        ),
      );
      return;
    }

    imageBytesList = _customImages
        .map((image) => image.bytes)
        .toList(growable: false);
    imageLabels = _customImages
        .map((image) => image.analysisLabelFor(_language))
        .toList(growable: false);
    imageQualityNotes = _customImages
        .map((image) => image.quality.promptSummaryFor(_language))
        .toList(growable: false);
    final regions = _customImages.map((image) => image.regionIndex).toSet();
    caseName = regions.length == 1
        ? _t(
            'Protocolo fotografico da regiao ${regions.first}',
            'Photographic protocol for region ${regions.first}',
          )
        : _t(
            'Protocolo fotografico de ${regions.length} regioes',
            'Photographic protocol for ${regions.length} regions',
          );
    region = regions.length == 1
        ? _t('Regiao ${regions.first} do corpo', 'Body region ${regions.first}')
        : _t('Multiplas regioes do corpo', 'Multiple body regions');
    visualSummary = _t(
      'protocolo fotografico guiado com ${imageBytesList.length} imagens rotuladas por regiao e distancia de captura; use foto geral para contexto, foto media para bordas, foto proxima para textura e comparacao com pele adjacente quando disponivel',
      'guided photographic protocol with ${imageBytesList.length} images labeled by region and capture distance; use overview photos for context, medium photos for borders, close photos for texture, and adjacent skin comparison when available',
    );

    final input = TriageInput(
      language: _language,
      caseName: caseName,
      region: region,
      visualSummary: visualSummary,
      imageBytesList: imageBytesList,
      imageLabels: imageLabels,
      imageQualityNotes: imageQualityNotes,
      hasNumbness: _hasNumbness,
      changedColor: _changedColor,
      hasContactWithConfirmedCase: _hasContactWithConfirmedCase,
      hasNervePainOrShock: _hasNervePainOrShock,
      hasMuscleWeakness: _hasMuscleWeakness,
      hasDrynessOrHairLoss: _hasDrynessOrHairLoss,
      hasMultipleLesions: _hasMultipleLesions,
      hasWoundOrBurnWithoutPain: _hasWoundOrBurnWithoutPain,
      notes: _notesController.text.trim(),
      duration: _duration,
    );

    setState(() {
      _isAnalyzing = true;
      _errorMessage = null;
    });

    try {
      final result = await _engine.analyze(input);
      SavedCaseRecord? savedRecord;
      Object? saveError;

      try {
        savedRecord = await _caseRepository.saveCase(
          patient: activePatient,
          caseName: caseName,
          imageBytesList: imageBytesList,
          result: result,
        );
      } catch (error) {
        saveError = error;
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _result = result;
        _errorMessage = null;
        if (savedRecord != null) {
          _savedCases = [savedRecord, ..._savedCases];
        }
      });

      if (saveError == null) {
        _showMessage(
          _t(
            'Analise salva no historico local do paciente.',
            'Analysis saved to the patient local history.',
          ),
        );
      } else {
        _showMessage(
          _t(
            'Analise gerada, mas nao foi possivel salvar no historico local.',
            'Analysis was generated, but could not be saved to local history.',
          ),
        );
      }
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorMessage = _friendlyAnalysisErrorMessage(
          error.message ?? error.code,
        );
        _result = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorMessage = '$error';
        _result = null;
      });
    } finally {
      if (mounted) {
        setState(() => _isAnalyzing = false);
      }
    }
  }

  void _showMessage(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  /// Translate low-level LiteRT/Gemma failures into field-oriented guidance.
  String _friendlyAnalysisErrorMessage(String message) {
    final normalized = _normalizedFactorText(message);
    if (normalized.contains('input token') ||
        normalized.contains('maximum number of tokens') ||
        normalized.contains('too long') ||
        normalized.contains('4096')) {
      return _t(
        'O conjunto de fotos ficou grande para a janela local do Gemma 4. Use ate $_maxAnalysisImages fotos: 3 de uma regiao ou 3 fotos por regiao em ate 2 regioes.',
        'The photo set is too large for the local Gemma 4 context. Use up to $_maxAnalysisImages photos: 3 from one region or 3 photos per region across up to 2 regions.',
      );
    }
    return message;
  }

  void _selectLanguage(AppLanguage language) {
    setState(() {
      _selectedLanguage = language;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_showSplash) {
      return const Scaffold(body: _SplashScreen());
    }

    if (_selectedLanguage == null) {
      return Scaffold(
        body: _LanguageSelectionScreen(onSelectLanguage: _selectLanguage),
      );
    }

    return AppLanguageScope(
      language: _language,
      child: Scaffold(
        key: _scaffoldKey,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.menu_rounded),
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          title: Row(
            children: [
              Icon(
                Icons.health_and_safety_rounded,
                color: Theme.of(context).colorScheme.primary,
                size: 24,
              ),
              const SizedBox(width: 8),
              const Text('Hansen Guard'),
            ],
          ),
          actions: [
            _ModelStatusChip(
              isReady: _isModelReady,
              isInitializing: _isInitializing,
            ),
            const SizedBox(width: 8),
          ],
        ),
        drawer: _AppDrawer(
          language: _language,
          onChangeLanguage: () {
            Navigator.of(context).pop();
            setState(() => _selectedLanguage = null);
          },
        ),
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: KeyedSubtree(
              key: ValueKey(_currentTab.name),
              child: switch (_currentTab) {
                _AppTab.home => _buildDashboard(context),
                _AppTab.newCase => _buildNewCaseFlow(context),
                _AppTab.history => _buildHistoryScreen(context),
                _AppTab.settings => _buildSettingsScreen(context),
              },
            ),
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _currentTab.index,
          onDestinationSelected: (index) {
            _selectTab(_AppTab.values[index]);
          },
          destinations: [
            for (final tab in _AppTab.values)
              NavigationDestination(
                icon: Icon(tab.icon),
                selectedIcon: Icon(tab.activeIcon),
                label: tab.labelFor(_language),
              ),
          ],
        ),
      ),
    );
  }

  // ──────────────────────────────────────────
  // DASHBOARD / HOME
  // ──────────────────────────────────────────

  Widget _buildDashboard(BuildContext context) {
    final recentCases = _savedCases.take(3).toList(growable: false);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        // Hero card
        _DashboardHeroCard(
          isModelReady: _isModelReady,
          isInitializing: _isInitializing,
          onNewCase: () {
            _selectTab(_AppTab.newCase);
            if (!_hasActivePatient) {
              _goToTriageStep(0);
            }
          },
        ),
        const SizedBox(height: 20),

        // Quick actions grid
        _SectionLabel(
          title: _t('Acoes rapidas', 'Quick actions'),
          icon: Icons.flash_on_rounded,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _DashboardActionCard(
                icon: Icons.add_circle_rounded,
                label: _t('Novo\nAtendimento', 'New\nConsultation'),
                color: const Color(0xFF0F766E),
                onTap: () {
                  _selectTab(_AppTab.newCase);
                  if (!_hasActivePatient) {
                    _goToTriageStep(0);
                  }
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _DashboardActionCard(
                icon: Icons.history_rounded,
                label: _t('Historico\nRecente', 'Recent\nHistory'),
                color: const Color(0xFF1E40AF),
                onTap: () => _selectTab(_AppTab.history),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _DashboardActionCard(
                icon: Icons.settings_rounded,
                label: _t('Config\nModelo', 'Model\nConfig'),
                color: const Color(0xFF7C3AED),
                onTap: () => _selectTab(_AppTab.settings),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),

        // Status cards
        _SectionLabel(
          title: _t('Status do sistema', 'System status'),
          icon: Icons.monitor_heart_outlined,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _StatusCard(
                icon: _isModelReady
                    ? Icons.offline_bolt_rounded
                    : _isInitializing
                    ? Icons.hourglass_top_rounded
                    : Icons.cloud_off_rounded,
                title: _isModelReady
                    ? _t('IA Pronta', 'AI Ready')
                    : _isInitializing
                    ? _t('Carregando...', 'Loading...')
                    : _t('IA Offline', 'AI Offline'),
                subtitle: _isModelReady
                    ? _t('Gemma 4 ativo', 'Gemma 4 active')
                    : _t('Verificar modelo', 'Check model'),
                color: _isModelReady
                    ? const Color(0xFF059669)
                    : _isInitializing
                    ? const Color(0xFFD97706)
                    : const Color(0xFFDC2626),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatusCard(
                icon: Icons.folder_outlined,
                title: '${_savedCases.length}',
                subtitle: _t('Casos salvos', 'Saved cases'),
                color: const Color(0xFF1E40AF),
              ),
            ),
          ],
        ),

        if (!_isModelReady && !_isInitializing && _errorMessage != null) ...[
          const SizedBox(height: 16),
          _InlineNotice(
            icon: Icons.warning_amber_rounded,
            color: const Color(0xFFD97706),
            title: _t('Modelo nao carregado', 'Model not loaded'),
            message: _t(
              'Verifique se o arquivo .litertlm esta presente no dispositivo.',
              'Check if the .litertlm file is present on the device.',
            ),
            actionLabel: _t('Tentar novamente', 'Try again'),
            onAction: () => _initializeModel(autoTriggered: false),
          ),
        ],

        // Recent history
        if (recentCases.isNotEmpty) ...[
          const SizedBox(height: 24),
          _SectionLabel(
            title: _t('Ultimos atendimentos', 'Recent consultations'),
            icon: Icons.schedule_rounded,
            trailing: TextButton(
              onPressed: () => _selectTab(_AppTab.history),
              child: Text(_t('Ver todos', 'View all')),
            ),
          ),
          const SizedBox(height: 12),
          for (final record in recentCases) ...[
            _HistoryTile(
              record: record,
              onTap: () => unawaited(_showSavedCaseDetails(record)),
            ),
            const SizedBox(height: 10),
          ],
        ],

        // Active patient banner
        if (_hasActivePatient) ...[
          const SizedBox(height: 24),
          _ActiveCaseBanner(
            patient: _activePatient!,
            onContinue: () {
              _selectTab(_AppTab.newCase);
            },
          ),
        ],
      ],
    );
  }

  // ──────────────────────────────────────────
  // NEW CASE FLOW (step-by-step)
  // ──────────────────────────────────────────

  Widget _buildNewCaseFlow(BuildContext context) {
    return Column(
      children: [
        // Step indicator
        _TriageStepIndicator(
          currentStep: _triageStep,
          hasPatient: _hasActivePatient,
          hasPhotos: _hasCustomImages,
          hasResult: _result != null,
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: KeyedSubtree(
              key: ValueKey('step-$_triageStep'),
              child: switch (_triageStep) {
                0 => _buildPatientStep(context),
                1 => _buildPhotosStep(context),
                2 => _buildQuestionsStep(context),
                _ => _buildResultStep(context),
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPatientStep(BuildContext context) {
    if (_activePatient != null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          _ActivePatientCard(
            patient: _activePatient!,
            onNewPatient: _busy ? null : () => unawaited(_startNewPatient()),
            onContinue: () => _goToTriageStep(1),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        _PatientEntryCard(
          nameController: _patientNameController,
          ageController: _patientAgeController,
          selectedSex: _patientSex,
          onSexChanged: (sex) => setState(() => _patientSex = sex),
          onCreatePatient: _registerPatient,
          isBusy: _isAnalyzing,
        ),
      ],
    );
  }

  Widget _buildPhotosStep(BuildContext context) {
    if (!_hasActivePatient) {
      return Center(
        child: _EmptyStateCard(
          icon: Icons.person_add_alt_1_rounded,
          title: _t('Cadastre o paciente', 'Register the patient'),
          subtitle: _t(
            'Volte ao passo anterior e registre o paciente primeiro.',
            'Go back to the previous step and register the patient first.',
          ),
          actionLabel: _t('Ir para cadastro', 'Go to registration'),
          onAction: () => _goToTriageStep(0),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        _ImagePanel(
          customImages: _customImages,
          selectedCustomImageIndex: _selectedCustomImageIndex,
          protocolRegionCount: _protocolRegionCount,
          onCaptureProtocolPhoto: _captureProtocolPhoto,
          onPickProtocolGalleryPhoto: _pickProtocolGalleryPhoto,
          onPickProtocolSampleImage: _pickProtocolSampleImage,
          onDeleteProtocolPhoto: _deleteProtocolPhoto,
          onAddRegion: _addProtocolRegion,
          onClearCustomImages: _clearCustomImages,
          onCustomImageSelected: _selectCustomImage,
          onCustomImageDeleted: _deleteCustomImage,
          isPickingImage: _isPickingImage,
          canPickImage: _canAddMoreImages,
          canAddRegion: _canAddProtocolRegion,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () => _goToTriageStep(0),
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: Text(_t('Paciente', 'Patient')),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _hasCustomImages ? () => _goToTriageStep(2) : null,
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              label: Text(_t('Questionario', 'Questionnaire')),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildQuestionsStep(BuildContext context) {
    if (!_hasActivePatient) {
      return Center(
        child: _EmptyStateCard(
          icon: Icons.person_add_alt_1_rounded,
          title: _t('Cadastre o paciente', 'Register the patient'),
          subtitle: _t(
            'Volte ao passo anterior e registre o paciente primeiro.',
            'Go back to the previous step and register the patient first.',
          ),
          actionLabel: _t('Ir para cadastro', 'Go to registration'),
          onAction: () => _goToTriageStep(0),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        _QuestionsPanel(
          hasNumbness: _hasNumbness,
          changedColor: _changedColor,
          hasContactWithConfirmedCase: _hasContactWithConfirmedCase,
          hasNervePainOrShock: _hasNervePainOrShock,
          hasMuscleWeakness: _hasMuscleWeakness,
          hasDrynessOrHairLoss: _hasDrynessOrHairLoss,
          hasMultipleLesions: _hasMultipleLesions,
          hasWoundOrBurnWithoutPain: _hasWoundOrBurnWithoutPain,
          duration: _duration,
          notesController: _notesController,
          onNumbnessChanged: (value) {
            setState(() {
              _hasNumbness = value;
              _result = null;
            });
          },
          onColorChanged: (value) {
            setState(() {
              _changedColor = value;
              _result = null;
            });
          },
          onContactChanged: (value) {
            setState(() {
              _hasContactWithConfirmedCase = value;
              _result = null;
            });
          },
          onNervePainChanged: (value) {
            setState(() {
              _hasNervePainOrShock = value;
              _result = null;
            });
          },
          onWeaknessChanged: (value) {
            setState(() {
              _hasMuscleWeakness = value;
              _result = null;
            });
          },
          onDrynessChanged: (value) {
            setState(() {
              _hasDrynessOrHairLoss = value;
              _result = null;
            });
          },
          onMultipleLesionsChanged: (value) {
            setState(() {
              _hasMultipleLesions = value;
              _result = null;
            });
          },
          onWoundOrBurnChanged: (value) {
            setState(() {
              _hasWoundOrBurnWithoutPain = value;
              _result = null;
            });
          },
          onDurationChanged: (value) {
            setState(() {
              _duration = value;
              _result = null;
            });
          },
          onNotesChanged: (_) => setState(() => _result = null),
          onAnalyze: () async {
            await _runAnalysis();
            if (_result != null && mounted) {
              _goToTriageStep(3);
            }
          },
          canAnalyze: !_busy && _hasCustomImages,
          isAnalyzing: _isAnalyzing,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () => _goToTriageStep(1),
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: Text(_t('Fotos', 'Photos')),
            ),
            const Spacer(),
          ],
        ),
      ],
    );
  }

  Widget _buildResultStep(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        if (_isAnalyzing)
          const _RunningResult()
        else if (_errorMessage != null && _result == null)
          _AnalysisErrorNotice(
            message: _errorMessage!,
            onRetry: () async {
              await _runAnalysis();
              if (_result != null && mounted) {
                _goToTriageStep(3);
              }
            },
          )
        else if (_result != null)
          _ResultPanel(result: _result!)
        else
          _EmptyResult(modelReady: _isModelReady),
        const SizedBox(height: 16),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () => _goToTriageStep(2),
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: Text(_t('Questionario', 'Questionnaire')),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: () {
                unawaited(_startNewPatient());
              },
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
              label: Text(_t('Novo caso', 'New case')),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            ),
          ],
        ),
      ],
    );
  }

  // ──────────────────────────────────────────
  // HISTORY SCREEN
  // ──────────────────────────────────────────

  Widget _buildHistoryScreen(BuildContext context) {
    if (_savedCases.isEmpty && !_isLoadingCases) {
      return Center(
        child: _EmptyStateCard(
          icon: Icons.history_rounded,
          title: _t('Nenhum caso salvo', 'No saved cases'),
          subtitle: _t(
            'Os resultados das triagens aparecerao aqui automaticamente.',
            'Triage results will appear here automatically.',
          ),
          actionLabel: _t('Iniciar atendimento', 'Start consultation'),
          onAction: () => _selectTab(_AppTab.newCase),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: TextField(
            controller: _historySearchController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: _t(
                'Buscar paciente por nome',
                'Search patient by name',
              ),
              suffixIcon: _historySearchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: () {
                        _historySearchController.clear();
                        setState(() {});
                      },
                    )
                  : null,
            ),
          ),
        ),
        if (_isLoadingCases)
          const Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(),
          )
        else
          Expanded(
            child: _visibleSavedCases.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        _t(
                          'Nenhum paciente encontrado.',
                          'No patient was found.',
                        ),
                        style: TextStyle(color: Color(0xFF64748B)),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                    itemCount: _visibleSavedCases.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final record = _visibleSavedCases[index];
                      return _HistoryTile(
                        record: record,
                        onTap: () => unawaited(_showSavedCaseDetails(record)),
                        onDelete: () => unawaited(_deleteSavedCase(record)),
                      );
                    },
                  ),
          ),
      ],
    );
  }

  Widget _buildSettingsScreen(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        _SectionLabel(
          title: _t('Modelo de IA', 'AI Model'),
          icon: Icons.psychology_rounded,
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _isModelReady
                          ? Icons.check_circle_rounded
                          : Icons.error_outline_rounded,
                      color: _isModelReady
                          ? const Color(0xFF059669)
                          : const Color(0xFFDC2626),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Gemma 4 E2B LiteRT-LM',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _isModelReady
                                ? _t('Carregado e pronto', 'Loaded and ready')
                                : _isInitializing
                                ? _t('Carregando...', 'Loading...')
                                : _t('Nao carregado', 'Not loaded'),
                            style: TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (_errorMessage != null && !_isModelReady) ...[
                  const SizedBox(height: 12),
                  Text(
                    _errorMessage!,
                    style: TextStyle(color: Color(0xFFDC2626), fontSize: 13),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _isInitializing
                        ? null
                        : () => _initializeModel(autoTriggered: false),
                    icon: Icon(
                      _isInitializing
                          ? Icons.hourglass_top_rounded
                          : Icons.refresh_rounded,
                    ),
                    label: Text(
                      _isInitializing
                          ? _t('Carregando...', 'Loading...')
                          : _t('Recarregar modelo', 'Reload model'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        _SectionLabel(
          title: _t('Idioma', 'Language'),
          icon: Icons.translate_rounded,
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              for (final lang in AppLanguage.values) ...[
                ListTile(
                  leading: Icon(
                    _language == lang
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_off_rounded,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(lang.label),
                  onTap: () => setState(() => _selectedLanguage = lang),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                if (lang != AppLanguage.values.last) const Divider(),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),
        _SectionLabel(
          title: _t('Informacoes', 'Information'),
          icon: Icons.info_outline_rounded,
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(_t('Sobre o app', 'About the app')),
                trailing: const Icon(Icons.chevron_right_rounded),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                onTap: () {
                  showAboutDialog(
                    context: context,
                    applicationName: 'Hansen Guard',
                    applicationVersion: '1.0.0',
                    applicationLegalese: _t(
                      'Triagem comunitaria de hanseniase com IA offline.\nNao substitui avaliacao clinica presencial.',
                      'Community leprosy triage with offline AI.\nDoes not replace in-person clinical evaluation.',
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showSavedCaseDetails(SavedCaseRecord record) async {
    final shouldDelete = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) =>
            _SavedCaseDetailsScreen(record: record, language: _language),
      ),
    );

    if (shouldDelete == true) {
      await _deleteSavedCase(record, requiresConfirmation: false);
    }
  }
}

class _AnalysisErrorNotice extends StatelessWidget {
  const _AnalysisErrorNotice({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return _InlineNotice(
      icon: Icons.warning_amber_rounded,
      color: const Color(0xFFDC2626),
      title: _tr(
        context,
        'A analise nao retornou informacao suficiente.',
        'The analysis did not return enough information.',
      ),
      message: message,
      actionLabel: _tr(context, 'Tentar novamente', 'Try again'),
      onAction: () => onRetry(),
    );
  }
}

// ──────────────────────────────────────────
// NEW DESIGN SYSTEM WIDGETS
// ──────────────────────────────────────────

class _ModelStatusChip extends StatelessWidget {
  const _ModelStatusChip({required this.isReady, required this.isInitializing});

  final bool isReady;
  final bool isInitializing;

  @override
  Widget build(BuildContext context) {
    final color = isReady
        ? const Color(0xFF059669)
        : isInitializing
        ? const Color(0xFFD97706)
        : const Color(0xFFDC2626);
    final label = isReady
        ? _tr(context, 'IA Pronta', 'AI Ready')
        : isInitializing
        ? _tr(context, 'Carregando', 'Loading')
        : _tr(context, 'Offline', 'Offline');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _AppDrawer extends StatelessWidget {
  const _AppDrawer({required this.language, required this.onChangeLanguage});

  final AppLanguage language;
  final VoidCallback onChangeLanguage;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                color: colors.primaryContainer.withValues(alpha: 0.3),
              ),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: colors.primary,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.health_and_safety_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'Hansen Guard',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          language.pick(
                            'Triagem comunitaria offline',
                            'Offline community triage',
                          ),
                          style: TextStyle(
                            color: Color(0xFF64748B),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            _DrawerItem(
              icon: Icons.translate_rounded,
              label: language.pick('Trocar idioma', 'Change language'),
              onTap: onChangeLanguage,
            ),
            _DrawerItem(
              icon: Icons.help_outline_rounded,
              label: language.pick('Ajuda', 'Help'),
              onTap: () => Navigator.of(context).pop(),
            ),
            _DrawerItem(
              icon: Icons.info_outline_rounded,
              label: language.pick('Sobre', 'About'),
              onTap: () {
                Navigator.of(context).pop();
                showAboutDialog(
                  context: context,
                  applicationName: 'Hansen Guard',
                  applicationVersion: '1.0.0',
                  applicationLegalese: language.pick(
                    'Triagem offline de hanseniase com IA.\nNao substitui avaliacao clinica.',
                    'Offline leprosy triage with AI.\nDoes not replace clinical evaluation.',
                  ),
                );
              },
            ),
            const Spacer(),
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Hansen Guard v1.0.0',
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF475569)),
      title: Text(label),
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
    );
  }
}

class _DashboardHeroCard extends StatelessWidget {
  const _DashboardHeroCard({
    required this.isModelReady,
    required this.isInitializing,
    required this.onNewCase,
  });

  final bool isModelReady;
  final bool isInitializing;
  final VoidCallback onNewCase;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Card(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              colors.primaryContainer.withValues(alpha: 0.3),
              Colors.white,
            ],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: colors.primary,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.health_and_safety_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _tr(
                            context,
                            'Bem-vindo ao Hansen Guard',
                            'Welcome to Hansen Guard',
                          ),
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _tr(
                            context,
                            'Triagem dermatologica offline com IA',
                            'Offline dermatologic triage with AI',
                          ),
                          style: const TextStyle(
                            color: Color(0xFF64748B),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onNewCase,
                  icon: const Icon(Icons.add_rounded),
                  label: Text(
                    _tr(
                      context,
                      'Iniciar novo atendimento',
                      'Start new consultation',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashboardActionCard extends StatelessWidget {
  const _DashboardActionCard({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: color, size: 26),
              ),
              const SizedBox(height: 10),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF334155),
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.30)),
          color: color.withValues(alpha: 0.05),
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontWeight: FontWeight.w700, color: color),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    style: TextStyle(
                      height: 1.4,
                      color: color.withValues(alpha: 0.8),
                      fontSize: 13,
                    ),
                  ),
                  if (actionLabel != null && onAction != null) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: onAction,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(actionLabel!),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: color,
                        side: BorderSide(color: color.withValues(alpha: 0.4)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title, required this.icon, this.trailing});

  final String title;
  final IconData icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: const Color(0xFF64748B)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Color(0xFF475569),
              letterSpacing: 0.3,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class _ActiveCaseBanner extends StatelessWidget {
  const _ActiveCaseBanner({required this.patient, required this.onContinue});

  final PatientProfile patient;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Card(
      child: InkWell(
        onTap: onContinue,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: colors.primaryContainer,
                foregroundColor: colors.onPrimaryContainer,
                child: const Icon(Icons.person_rounded, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _tr(context, 'Caso em andamento', 'Case in progress'),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF64748B),
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      patient.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 16,
                color: colors.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TriageStepIndicator extends StatelessWidget {
  const _TriageStepIndicator({
    required this.currentStep,
    required this.hasPatient,
    required this.hasPhotos,
    required this.hasResult,
  });

  final int currentStep;
  final bool hasPatient;
  final bool hasPhotos;
  final bool hasResult;

  @override
  Widget build(BuildContext context) {
    final language = AppLanguageScope.of(context);
    final colors = Theme.of(context).colorScheme;

    final steps = [
      (
        icon: Icons.person_rounded,
        label: language.pick('Paciente', 'Patient'),
        done: hasPatient,
      ),
      (
        icon: Icons.camera_alt_rounded,
        label: language.pick('Fotos', 'Photos'),
        done: hasPhotos,
      ),
      (
        icon: Icons.fact_check_rounded,
        label: language.pick('Perguntas', 'Questions'),
        done: currentStep > 2,
      ),
      (
        icon: Icons.analytics_rounded,
        label: language.pick('Resultado', 'Result'),
        done: hasResult,
      ),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Row(
        children: [
          for (var i = 0; i < steps.length; i++) ...[
            Expanded(
              child: GestureDetector(
                onTap: () {
                  if (context.findAncestorStateOfType<_TriageScreenState>()
                      case final state?) {
                    state._goToTriageStep(i);
                  }
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: i == currentStep
                            ? colors.primary
                            : steps[i].done
                            ? colors.primary.withValues(alpha: 0.15)
                            : const Color(0xFFF1F5F9),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        steps[i].done && i != currentStep
                            ? Icons.check_rounded
                            : steps[i].icon,
                        size: 18,
                        color: i == currentStep
                            ? Colors.white
                            : steps[i].done
                            ? colors.primary
                            : const Color(0xFF94A3B8),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      steps[i].label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: i == currentStep
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: i == currentStep
                            ? colors.primary
                            : const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (i < steps.length - 1)
              Expanded(
                flex: 0,
                child: Container(
                  width: 24,
                  height: 2,
                  color: steps[i].done
                      ? colors.primary.withValues(alpha: 0.3)
                      : const Color(0xFFE2E8F0),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.record,
    required this.onTap,
    this.onDelete,
  });

  final SavedCaseRecord record;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final language = AppLanguageScope.of(context);
    final firstImagePath = record.imagePaths.isNotEmpty
        ? record.imagePaths.first
        : null;

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: firstImagePath == null
                      ? const ColoredBox(
                          color: Color(0xFFF1F5F9),
                          child: Icon(
                            Icons.image_outlined,
                            color: Color(0xFF94A3B8),
                          ),
                        )
                      : Image.file(
                          File(firstImagePath),
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              const ColoredBox(
                                color: Color(0xFFF1F5F9),
                                child: Icon(
                                  Icons.broken_image_outlined,
                                  color: Color(0xFF94A3B8),
                                ),
                              ),
                        ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.patient.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        _RiskDot(level: record.result.level),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            record.result.level.labelFor(language),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: record.result.level.color,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${record.result.score}/100',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      record.subtitleFor(language),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ),
              ),
              if (onDelete != null)
                IconButton(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline_rounded),
                  iconSize: 20,
                  color: const Color(0xFF94A3B8),
                ),
              const Icon(Icons.chevron_right_rounded, color: Color(0xFFCBD5E1)),
            ],
          ),
        ),
      ),
    );
  }
}

class _RiskDot extends StatelessWidget {
  const _RiskDot({required this.level});

  final RiskLevel level;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: level.color, shape: BoxShape.circle),
    );
  }
}

class _EmptyStateCard extends StatelessWidget {
  const _EmptyStateCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 36, color: const Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Color(0xFF334155),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(height: 1.4, color: Color(0xFF64748B)),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              label: Text(actionLabel!),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActivePatientCard extends StatelessWidget {
  const _ActivePatientCard({
    required this.patient,
    required this.onNewPatient,
    required this.onContinue,
  });

  final PatientProfile patient;
  final VoidCallback? onNewPatient;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final language = AppLanguageScope.of(context);
    final colors = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: colors.primaryContainer,
                  foregroundColor: colors.onPrimaryContainer,
                  child: const Icon(Icons.person_rounded, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        patient.name,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        patient.summaryLabelFor(language),
                        style: const TextStyle(
                          color: Color(0xFF64748B),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onContinue,
                    icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                    label: Text(
                      _tr(context, 'Continuar triagem', 'Continue triage'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: onNewPatient,
                  child: Text(_tr(context, 'Trocar', 'Change')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.primary.withValues(alpha: 0.08),
            Colors.white,
            colors.primaryContainer.withValues(alpha: 0.15),
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: colors.primary,
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: colors.primary.withValues(alpha: 0.3),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: const Icon(
                Icons.health_and_safety_rounded,
                size: 52,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Hansen Guard',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w900,
                color: Color(0xFF0F172A),
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Dermatologic Triage · Offline AI',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Color(0xFF64748B),
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: colors.primary.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LanguageSelectionScreen extends StatelessWidget {
  const _LanguageSelectionScreen({required this.onSelectLanguage});

  final ValueChanged<AppLanguage> onSelectLanguage;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.primary.withValues(alpha: 0.06),
            Colors.white,
            colors.primaryContainer.withValues(alpha: 0.12),
          ],
        ),
      ),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: 0.10),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.translate_rounded,
                      size: 36,
                      color: colors.primary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Escolha o idioma\nChoose your language',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0F172A),
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Selecione como deseja visualizar o app.\nSelect how you want to view the app.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      height: 1.4,
                      color: Color(0xFF64748B),
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 32),
                  for (final language in AppLanguage.values) ...[
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => onSelectLanguage(language),
                        icon: const Icon(Icons.language_rounded),
                        label: Text(language.actionLabel),
                      ),
                    ),
                    if (language != AppLanguage.values.last)
                      const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// _ActivePatientHeader and _WelcomeHero removed — replaced by new design system

class _PatientEntryCard extends StatelessWidget {
  const _PatientEntryCard({
    required this.nameController,
    required this.ageController,
    required this.selectedSex,
    required this.onSexChanged,
    required this.onCreatePatient,
    required this.isBusy,
  });

  final TextEditingController nameController;
  final TextEditingController ageController;
  final PatientSex selectedSex;
  final ValueChanged<PatientSex> onSexChanged;
  final VoidCallback onCreatePatient;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final language = AppLanguageScope.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(
              icon: Icons.person_add_alt_1_outlined,
              title: _tr(context, 'Adicionar paciente', 'Add patient'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: _tr(context, 'Nome', 'Name'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ageController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: _tr(context, 'Idade', 'Age'),
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<PatientSex>(
              showSelectedIcon: false,
              segments: [
                for (final sex in PatientSex.values)
                  ButtonSegment(
                    value: sex,
                    label: Text(
                      sex.labelFor(language),
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
              selected: {selectedSex},
              onSelectionChanged: (selection) => onSexChanged(selection.single),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: isBusy ? null : onCreatePatient,
              icon: const Icon(Icons.playlist_add_check_circle_outlined),
              label: Text(
                _tr(
                  context,
                  'Adicionar pessoa e continuar',
                  'Add patient and continue',
                ),
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _tr(
                context,
                'Depois disso o app libera camera, galeria, imagens de exemplo e o questionario guiado.',
                'After that, the app unlocks camera, gallery, sample images, and the guided questionnaire.',
              ),
              style: const TextStyle(height: 1.35, color: Color(0xFF5D706C)),
            ),
          ],
        ),
      ),
    );
  }
}

// _SavedCasesPanel and _SavedCaseTile removed — replaced by _HistoryTile + inline history screen

class _SavedCasePreview extends StatelessWidget {
  const _SavedCasePreview({required this.record});

  final SavedCaseRecord record;

  @override
  Widget build(BuildContext context) {
    final language = AppLanguageScope.of(context);
    final firstImagePath = record.imagePaths.isNotEmpty
        ? record.imagePaths.first
        : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 96,
                height: 72,
                child: firstImagePath == null
                    ? const ColoredBox(
                        color: Color(0xFFE9EFED),
                        child: Icon(Icons.image_outlined),
                      )
                    : Image.file(
                        File(firstImagePath),
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return const ColoredBox(
                            color: Color(0xFFE9EFED),
                            child: Icon(Icons.broken_image_outlined),
                          );
                        },
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.displayTitleFor(language),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    record.subtitleFor(language),
                    style: const TextStyle(color: Color(0xFF5D706C)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SavedCaseDetailsScreen extends StatefulWidget {
  const _SavedCaseDetailsScreen({required this.record, required this.language});

  final SavedCaseRecord record;
  final AppLanguage language;

  @override
  State<_SavedCaseDetailsScreen> createState() =>
      _SavedCaseDetailsScreenState();
}

class _SavedCaseDetailsScreenState extends State<_SavedCaseDetailsScreen> {
  int _selectedImageIndex = 0;

  String _t(String portuguese, String english) {
    return widget.language.pick(portuguese, english);
  }

  Future<void> _requestDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(_t('Excluir do historico?', 'Delete from history?')),
          content: Text(
            _t(
              'As imagens e os dados desta analise serao removidos do dispositivo.',
              'The images and data from this analysis will be removed from the device.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_t('Cancelar', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_t('Excluir', 'Delete')),
            ),
          ],
        );
      },
    );

    if (!mounted || confirmed != true) {
      return;
    }

    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final hasImages = record.imagePaths.isNotEmpty;
    final safeIndex = hasImages
        ? _selectedImageIndex.clamp(0, record.imagePaths.length - 1)
        : 0;
    final activeImagePath = hasImages ? record.imagePaths[safeIndex] : null;

    return AppLanguageScope(
      language: widget.language,
      child: Scaffold(
        appBar: AppBar(
          title: Text(record.patient.name),
          actions: [
            IconButton(
              tooltip: _t('Excluir do historico', 'Delete from history'),
              onPressed: _requestDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1040),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.patient.name,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF173331),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      widget.language.pick(
                        '${record.patient.age} anos · ${record.patient.sex.labelFor(widget.language)} · ${record.createdAt.toLocal()}',
                        '${record.patient.age} years · ${record.patient.sex.labelFor(widget.language)} · ${record.createdAt.toLocal()}',
                      ),
                      style: const TextStyle(color: Color(0xFF5D706C)),
                    ),
                    const SizedBox(height: 16),
                    _SavedCasePreview(record: record),
                    const SizedBox(height: 16),
                    _SectionHeader(
                      icon: Icons.photo_library_outlined,
                      title: _t(
                        'Fotos salvas do paciente',
                        'Saved patient photos',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: AspectRatio(
                                aspectRatio: 4 / 3,
                                child: activeImagePath == null
                                    ? const ColoredBox(
                                        color: Color(0xFFE9EFED),
                                        child: Center(
                                          child: Icon(
                                            Icons.image_outlined,
                                            size: 48,
                                          ),
                                        ),
                                      )
                                    : Image.file(
                                        File(activeImagePath),
                                        fit: BoxFit.cover,
                                        errorBuilder:
                                            (context, error, stackTrace) {
                                              return const ColoredBox(
                                                color: Color(0xFFE9EFED),
                                                child: Center(
                                                  child: Icon(
                                                    Icons.broken_image_outlined,
                                                    size: 48,
                                                  ),
                                                ),
                                              );
                                            },
                                      ),
                              ),
                            ),
                            if (hasImages) ...[
                              const SizedBox(height: 12),
                              Text(
                                _t(
                                  '${record.imagePaths.length} foto(s) vinculada(s) a esta analise.',
                                  '${record.imagePaths.length} photo(s) linked to this analysis.',
                                ),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF173331),
                                ),
                              ),
                              const SizedBox(height: 10),
                              SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    for (
                                      var index = 0;
                                      index < record.imagePaths.length;
                                      index++
                                    ) ...[
                                      _SavedCaseImageThumb(
                                        imagePath: record.imagePaths[index],
                                        index: index,
                                        isSelected: index == safeIndex,
                                        onTap: () => setState(
                                          () => _selectedImageIndex = index,
                                        ),
                                      ),
                                      if (index < record.imagePaths.length - 1)
                                        const SizedBox(width: 10),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (record.result.regionFindings.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _SectionHeader(
                        icon: Icons.place_outlined,
                        title: _t('Achados por regiao', 'Findings by region'),
                      ),
                      const SizedBox(height: 8),
                      for (final finding in record.result.regionFindings)
                        _RegionFindingCard(finding: finding),
                    ] else ...[
                      const SizedBox(height: 16),
                      _StructuredListSection(
                        icon: Icons.visibility_outlined,
                        title: _t('Achados visuais', 'Visual findings'),
                        items: record.result.visualFindings,
                      ),
                    ],
                    if (record.result.riskFactors.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _StructuredListSection(
                        icon: Icons.trending_up_outlined,
                        title: _t(
                          'Fatores que elevaram o risco',
                          'Factors that raised the risk',
                        ),
                        items: record.result.riskFactors,
                      ),
                    ],
                    if (record.result.confidenceLimitingFactors.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _StructuredListSection(
                        icon: Icons.error_outline,
                        title: _t(
                          'Limites da confianca',
                          'Confidence limitations',
                        ),
                        items: record.result.confidenceLimitingFactors,
                      ),
                    ],
                    if (record.result.reassuringFactors.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _StructuredListSection(
                        icon: Icons.check_circle_outline,
                        title: _t(
                          'Fatores que reduzem a suspeita',
                          'Factors that lower suspicion',
                        ),
                        items: record.result.reassuringFactors,
                      ),
                    ],
                    const SizedBox(height: 16),
                    _RiskScoreCards(
                      visualTitle: _t(
                        'Risco visual dermatologico',
                        'Dermatologic visual risk',
                      ),
                      visualScore: record.result.visualRiskScore,
                      visualLevel: record.result.visualRiskLevel,
                      clinicalTitle: _t(
                        'Risco clinico-neural',
                        'Clinical-neural risk',
                      ),
                      clinicalScore: record.result.clinicalNeuralRiskScore,
                      clinicalLevel: record.result.clinicalNeuralRiskLevel,
                    ),
                    const SizedBox(height: 16),
                    _SectionHeader(
                      icon: Icons.psychology_alt_outlined,
                      title: _t('Raciocinio clinico', 'Clinical reasoning'),
                    ),
                    const SizedBox(height: 8),
                    for (final item in record.result.reasoning)
                      _ReasoningLine(text: item),
                    const SizedBox(height: 16),
                    _SectionHeader(
                      icon: Icons.assignment_late_outlined,
                      title: _t('Motivo do encaminhamento', 'Referral reason'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      record.result.referralReason,
                      style: const TextStyle(
                        height: 1.4,
                        color: Color(0xFF314744),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _SectionHeader(
                      icon: Icons.local_hospital_outlined,
                      title: _t('Proxima acao', 'Next action'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      record.result.nextAction,
                      style: const TextStyle(
                        height: 1.4,
                        color: Color(0xFF314744),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const _ClinicalSafetyNote(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SavedCaseImageThumb extends StatelessWidget {
  const _SavedCaseImageThumb({
    required this.imagePath,
    required this.index,
    required this.isSelected,
    required this.onTap,
  });

  final String imagePath;
  final int index;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Ink(
        width: 112,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? colors.primary : const Color(0xFFDCE5E2),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: AspectRatio(
                aspectRatio: 1,
                child: Image.file(
                  File(imagePath),
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return const ColoredBox(
                      color: Color(0xFFE9EFED),
                      child: Icon(Icons.broken_image_outlined),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _tr(context, 'Foto ${index + 1}', 'Photo ${index + 1}'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImagePanel extends StatelessWidget {
  const _ImagePanel({
    required this.customImages,
    required this.selectedCustomImageIndex,
    required this.protocolRegionCount,
    required this.onCaptureProtocolPhoto,
    required this.onPickProtocolGalleryPhoto,
    required this.onPickProtocolSampleImage,
    required this.onDeleteProtocolPhoto,
    required this.onAddRegion,
    required this.onClearCustomImages,
    required this.onCustomImageSelected,
    required this.onCustomImageDeleted,
    required this.isPickingImage,
    required this.canPickImage,
    required this.canAddRegion,
  });

  final List<SelectedTriageImage> customImages;
  final int selectedCustomImageIndex;
  final int protocolRegionCount;
  final Future<void> Function(int regionIndex, CaptureShotType shotType)
  onCaptureProtocolPhoto;
  final Future<void> Function(int regionIndex, CaptureShotType shotType)
  onPickProtocolGalleryPhoto;
  final Future<void> Function(
    int regionIndex,
    CaptureShotType shotType,
    SkinCase skinCase,
  )
  onPickProtocolSampleImage;
  final void Function(int regionIndex, CaptureShotType shotType)
  onDeleteProtocolPhoto;
  final VoidCallback onAddRegion;
  final VoidCallback onClearCustomImages;
  final ValueChanged<int> onCustomImageSelected;
  final ValueChanged<int> onCustomImageDeleted;
  final bool isPickingImage;
  final bool canPickImage;
  final bool canAddRegion;

  @override
  Widget build(BuildContext context) {
    final showingCustomImages = customImages.isNotEmpty;
    final safeSelectedIndex = showingCustomImages
        ? selectedCustomImageIndex.clamp(0, customImages.length - 1)
        : 0;
    final activeCustomImage = showingCustomImages
        ? customImages[safeSelectedIndex]
        : null;

    final String activeSourceLabel;
    final IconData activeSourceIcon;
    if (!showingCustomImages) {
      activeSourceLabel = _tr(
        context,
        'Nenhuma foto protocolada selecionada ainda',
        'No protocol photo selected yet',
      );
      activeSourceIcon = Icons.add_photo_alternate_outlined;
    } else {
      final regions = customImages.map((image) => image.regionIndex).toSet();
      activeSourceLabel = _tr(
        context,
        'Protocolo com ${customImages.length} foto(s) em ${regions.length} regiao(oes)',
        'Protocol with ${customImages.length} photo(s) across ${regions.length} region(s)',
      );
      activeSourceIcon = Icons.assignment_turned_in_outlined;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(
              icon: Icons.photo_camera_outlined,
              title: _tr(context, 'Protocolo de fotos', 'Photo protocol'),
            ),
            const SizedBox(height: 12),
            DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFFF4F7F6),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFDCE5E2)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          activeSourceIcon,
                          size: 18,
                          color: const Color(0xFF126A63),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            activeSourceLabel,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF173331),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      showingCustomImages
                          ? _tr(
                              context,
                              '${customImages.length}/$_maxAnalysisImages fotos rotuladas para analise conjunta. Toque numa miniatura para revisar.',
                              '${customImages.length}/$_maxAnalysisImages photos labeled for joint analysis. Tap a thumbnail to review.',
                            )
                          : _tr(
                              context,
                              'Capture foto geral, media e proxima. O app aceita ate 2 regioes e 6 fotos por analise para caber no Gemma 4 offline.',
                              'Capture overview, medium, and close photos. The app supports up to 2 regions and 6 photos per analysis to fit offline Gemma 4.',
                            ),
                      style: const TextStyle(
                        height: 1.35,
                        color: Color(0xFF3E5551),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const _PhotoCaptureGuidance(),
                    if (showingCustomImages) ...[
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: isPickingImage ? null : onClearCustomImages,
                        icon: const Icon(Icons.delete_outline),
                        label: Text(
                          _tr(
                            context,
                            'Limpar fotos do protocolo',
                            'Clear protocol photos',
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            for (
              var regionIndex = 1;
              regionIndex <= protocolRegionCount;
              regionIndex++
            ) ...[
              _ProtocolRegionCard(
                regionIndex: regionIndex,
                images: customImages
                    .where((image) => image.regionIndex == regionIndex)
                    .toList(growable: false),
                isPickingImage: isPickingImage,
                canPickImage: canPickImage,
                onCapturePhoto: (shotType) =>
                    onCaptureProtocolPhoto(regionIndex, shotType),
                onPickFromGallery: (shotType) =>
                    onPickProtocolGalleryPhoto(regionIndex, shotType),
                onPickSample: (shotType, skinCase) =>
                    onPickProtocolSampleImage(regionIndex, shotType, skinCase),
                onDeletePhoto: (shotType) =>
                    onDeleteProtocolPhoto(regionIndex, shotType),
              ),
              const SizedBox(height: 12),
            ],
            OutlinedButton.icon(
              onPressed: canAddRegion ? onAddRegion : null,
              icon: const Icon(Icons.add_location_alt_outlined),
              label: Text(
                _tr(context, 'Adicionar outra regiao', 'Add another region'),
              ),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: Color(0xFFE9EFED)),
                  child: showingCustomImages
                      ? Image.memory(
                          activeCustomImage!.bytes,
                          fit: BoxFit.cover,
                        )
                      : Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(
                                Icons.photo_camera_outlined,
                                size: 44,
                                color: Color(0xFF5D706C),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _tr(
                                  context,
                                  'Siga as etapas do protocolo para iniciar a triagem.',
                                  'Follow the protocol steps to start triage.',
                                ),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Color(0xFF5D706C),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ),
            if (activeCustomImage != null) ...[
              const SizedBox(height: 10),
              _QualityNotice(quality: activeCustomImage.quality),
            ],
            if (showingCustomImages) ...[
              const SizedBox(height: 12),
              Text(
                _tr(context, 'Fotos do protocolo', 'Protocol photos'),
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF173331),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (var index = 0; index < customImages.length; index++)
                    _CustomImageThumb(
                      image: customImages[index],
                      index: index,
                      isSelected: index == safeSelectedIndex,
                      onTap: () => onCustomImageSelected(index),
                      onDelete: () => onCustomImageDeleted(index),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PhotoCaptureGuidance extends StatelessWidget {
  const _PhotoCaptureGuidance();

  @override
  Widget build(BuildContext context) {
    final items = [
      _tr(context, 'Sem zoom digital', 'No digital zoom'),
      _tr(context, 'Boa luz uniforme', 'Good even lighting'),
      _tr(context, 'Evitar sombra forte', 'Avoid strong shadows'),
      _tr(context, 'Lesao centralizada', 'Center the lesion'),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in items)
          Chip(
            avatar: const Icon(Icons.check_outlined, size: 16),
            label: Text(item),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

class _ProtocolRegionCard extends StatelessWidget {
  const _ProtocolRegionCard({
    required this.regionIndex,
    required this.images,
    required this.isPickingImage,
    required this.canPickImage,
    required this.onCapturePhoto,
    required this.onPickFromGallery,
    required this.onPickSample,
    required this.onDeletePhoto,
  });

  final int regionIndex;
  final List<SelectedTriageImage> images;
  final bool isPickingImage;
  final bool canPickImage;
  final ValueChanged<CaptureShotType> onCapturePhoto;
  final ValueChanged<CaptureShotType> onPickFromGallery;
  final void Function(CaptureShotType shotType, SkinCase skinCase) onPickSample;
  final ValueChanged<CaptureShotType> onDeletePhoto;

  @override
  Widget build(BuildContext context) {
    SelectedTriageImage? imageFor(CaptureShotType shotType) {
      for (final image in images) {
        if (image.shotType == shotType) {
          return image;
        }
      }
      return null;
    }

    final completedRequired = CaptureShotType.values
        .where((shotType) => shotType.isRequired)
        .where((shotType) => imageFor(shotType) != null)
        .length;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFDCE5E2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _tr(context, 'Regiao $regionIndex', 'Region $regionIndex'),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF173331),
                    ),
                  ),
                ),
                Text(
                  _tr(
                    context,
                    '$completedRequired/3 obrigatorias',
                    '$completedRequired/3 required',
                  ),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF126A63),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final shotType in CaptureShotType.values) ...[
              _ProtocolShotRow(
                shotType: shotType,
                image: imageFor(shotType),
                isPickingImage: isPickingImage,
                canPickImage: canPickImage || imageFor(shotType) != null,
                onCapturePhoto: () => onCapturePhoto(shotType),
                onPickFromGallery: () => onPickFromGallery(shotType),
                onPickSample: (skinCase) => onPickSample(shotType, skinCase),
                onDeletePhoto: () => onDeletePhoto(shotType),
              ),
              if (shotType != CaptureShotType.values.last)
                const Divider(height: 14),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProtocolShotRow extends StatelessWidget {
  const _ProtocolShotRow({
    required this.shotType,
    required this.image,
    required this.isPickingImage,
    required this.canPickImage,
    required this.onCapturePhoto,
    required this.onPickFromGallery,
    required this.onPickSample,
    required this.onDeletePhoto,
  });

  final CaptureShotType shotType;
  final SelectedTriageImage? image;
  final bool isPickingImage;
  final bool canPickImage;
  final VoidCallback onCapturePhoto;
  final VoidCallback onPickFromGallery;
  final ValueChanged<SkinCase> onPickSample;
  final VoidCallback onDeletePhoto;

  @override
  Widget build(BuildContext context) {
    final language = AppLanguageScope.of(context);
    final hasImage = image != null;
    final quality = image?.quality;

    Future<void> openSamplePicker() async {
      final selected = await showModalBottomSheet<SkinCase>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) =>
            _SampleImagePickerSheet(cases: _cases, language: language),
      );

      if (selected != null) {
        onPickSample(selected);
      }
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(shotType.icon, color: const Color(0xFF126A63)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      shotType.labelFor(language),
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF173331),
                      ),
                    ),
                  ),
                  if (!shotType.isRequired)
                    Text(
                      _tr(context, 'Opcional', 'Optional'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF5D706C),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                shotType.instructionFor(language),
                style: const TextStyle(height: 1.3, color: Color(0xFF5D706C)),
              ),
              if (quality != null) ...[
                const SizedBox(height: 6),
                _QualityPill(quality: quality),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: canPickImage && !isPickingImage
                        ? onCapturePhoto
                        : null,
                    icon: Icon(
                      isPickingImage
                          ? Icons.hourglass_top
                          : Icons.add_a_photo_outlined,
                    ),
                    label: Text(
                      hasImage
                          ? _tr(context, 'Refazer', 'Retake')
                          : _tr(context, 'Camera', 'Camera'),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: canPickImage && !isPickingImage
                        ? onPickFromGallery
                        : null,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: Text(_tr(context, 'Galeria', 'Gallery')),
                  ),
                  Tooltip(
                    message: _tr(
                      context,
                      'Escolher imagem de exemplo',
                      'Choose sample image',
                    ),
                    child: OutlinedButton.icon(
                      key: ValueKey('sample-button-${shotType.name}'),
                      onPressed: canPickImage && !isPickingImage
                          ? openSamplePicker
                          : null,
                      icon: const Icon(Icons.collections_outlined),
                      label: Text(_tr(context, 'Exemplo', 'Sample')),
                    ),
                  ),
                  if (hasImage)
                    OutlinedButton.icon(
                      onPressed: isPickingImage ? null : onDeletePhoto,
                      icon: const Icon(Icons.delete_outline),
                      label: Text(_tr(context, 'Excluir', 'Delete')),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SampleImagePickerSheet extends StatelessWidget {
  const _SampleImagePickerSheet({required this.cases, required this.language});

  final List<SkinCase> cases;
  final AppLanguage language;

  @override
  Widget build(BuildContext context) {
    final height = math.min(MediaQuery.sizeOf(context).height * 0.76, 640.0);

    return SafeArea(
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      language.pick('Imagens de exemplo', 'Sample images'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF173331),
                      ),
                    ),
                  ),
                  Text(
                    language.pick(
                      '${cases.length} imagens',
                      '${cases.length} images',
                    ),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF5D706C),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: GridView.builder(
                  itemCount: cases.length,
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 150,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.78,
                  ),
                  itemBuilder: (context, index) {
                    final skinCase = cases[index];
                    return _SampleImageTile(
                      key: ValueKey('sample-case-${skinCase.assetPath}'),
                      skinCase: skinCase,
                      language: language,
                      onTap: () => Navigator.of(context).pop(skinCase),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SampleImageTile extends StatelessWidget {
  const _SampleImageTile({
    super.key,
    required this.skinCase,
    required this.language,
    required this.onTap,
  });

  final SkinCase skinCase;
  final AppLanguage language;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: skinCase.nameFor(language),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFDCE5E2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(7),
                  ),
                  child: Image.asset(
                    skinCase.assetPath,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return const ColoredBox(
                        color: Color(0xFFE8EFEC),
                        child: Center(
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: Color(0xFF5D706C),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  skinCase.nameFor(language),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF173331),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QualityPill extends StatelessWidget {
  const _QualityPill({required this.quality});

  final PhotoQualityReport quality;

  @override
  Widget build(BuildContext context) {
    final color = quality.isAcceptable
        ? const Color(0xFF2D6B43)
        : const Color(0xFF9A5D00);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              quality.isNotEvaluated
                  ? Icons.image_outlined
                  : quality.isAcceptable
                  ? Icons.check_circle_outline
                  : Icons.warning_amber_rounded,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                quality.statusLabelFor(AppLanguageScope.of(context)),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QualityNotice extends StatelessWidget {
  const _QualityNotice({required this.quality});

  final PhotoQualityReport quality;

  @override
  Widget build(BuildContext context) {
    final language = AppLanguageScope.of(context);
    final isIllustrative = quality.isNotEvaluated;
    final color = isIllustrative
        ? const Color(0xFF126A63)
        : quality.isAcceptable
        ? const Color(0xFF2D6B43)
        : const Color(0xFF9A5D00);
    final message = isIllustrative
        ? _tr(
            context,
            'Imagem ilustrativa de exemplo; a qualidade tecnica nao sera usada para limitar a analise.',
            'Illustrative sample image; technical quality will not limit the analysis.',
          )
        : quality.isAcceptable
        ? _tr(
            context,
            'Validacao automatica sem alertas de luz, contraste ou nitidez.',
            'Automatic validation found no issues with lighting, contrast, or sharpness.',
          )
        : _tr(
            context,
            'Alertas automaticos: ${quality.localizedWarningsFor(language).join(', ')}.',
            'Automatic alerts: ${quality.localizedWarningsFor(language).join(', ')}.',
          );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isIllustrative
                  ? Icons.image_outlined
                  : quality.isAcceptable
                  ? Icons.check_circle_outline
                  : Icons.warning_amber_rounded,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  height: 1.35,
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CustomImageThumb extends StatelessWidget {
  const _CustomImageThumb({
    required this.image,
    required this.index,
    required this.isSelected,
    required this.onTap,
    required this.onDelete,
  });

  final SelectedTriageImage image;
  final int index;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final language = AppLanguageScope.of(context);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Ink(
        width: 104,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? colors.primary : const Color(0xFFDCE5E2),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: AspectRatio(
                aspectRatio: 1,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(image.bytes, fit: BoxFit.cover),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.62),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: IconButton(
                          tooltip: _tr(context, 'Excluir foto', 'Delete photo'),
                          onPressed: onDelete,
                          icon: const Icon(Icons.close, color: Colors.white),
                          iconSize: 16,
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints.tightFor(
                            width: 30,
                            height: 30,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              image.protocolLabelFor(language),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  image.quality.isNotEvaluated
                      ? Icons.image_outlined
                      : image.quality.isAcceptable
                      ? Icons.check_circle_outline
                      : Icons.warning_amber_rounded,
                  size: 14,
                  color: image.quality.isAcceptable
                      ? const Color(0xFF2D6B43)
                      : const Color(0xFF9A5D00),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    image.quality.statusLabelFor(language),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF5D706C),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QuestionsPanel extends StatelessWidget {
  const _QuestionsPanel({
    required this.hasNumbness,
    required this.changedColor,
    required this.hasContactWithConfirmedCase,
    required this.hasNervePainOrShock,
    required this.hasMuscleWeakness,
    required this.hasDrynessOrHairLoss,
    required this.hasMultipleLesions,
    required this.hasWoundOrBurnWithoutPain,
    required this.duration,
    required this.notesController,
    required this.onNumbnessChanged,
    required this.onColorChanged,
    required this.onContactChanged,
    required this.onNervePainChanged,
    required this.onWeaknessChanged,
    required this.onDrynessChanged,
    required this.onMultipleLesionsChanged,
    required this.onWoundOrBurnChanged,
    required this.onDurationChanged,
    required this.onNotesChanged,
    required this.onAnalyze,
    required this.canAnalyze,
    required this.isAnalyzing,
  });

  final bool hasNumbness;
  final bool changedColor;
  final bool hasContactWithConfirmedCase;
  final bool hasNervePainOrShock;
  final bool hasMuscleWeakness;
  final bool hasDrynessOrHairLoss;
  final bool hasMultipleLesions;
  final bool hasWoundOrBurnWithoutPain;
  final DurationOption duration;
  final TextEditingController notesController;
  final ValueChanged<bool> onNumbnessChanged;
  final ValueChanged<bool> onColorChanged;
  final ValueChanged<bool> onContactChanged;
  final ValueChanged<bool> onNervePainChanged;
  final ValueChanged<bool> onWeaknessChanged;
  final ValueChanged<bool> onDrynessChanged;
  final ValueChanged<bool> onMultipleLesionsChanged;
  final ValueChanged<bool> onWoundOrBurnChanged;
  final ValueChanged<DurationOption> onDurationChanged;
  final ValueChanged<String> onNotesChanged;
  final Future<void> Function() onAnalyze;
  final bool canAnalyze;
  final bool isAnalyzing;

  @override
  Widget build(BuildContext context) {
    final language = AppLanguageScope.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionHeader(
              icon: Icons.fact_check_outlined,
              title: _tr(context, 'Perguntas guiadas', 'Guided questions'),
            ),
            const SizedBox(height: 10),
            _SwitchQuestion(
              title: _tr(
                context,
                'Tem dormencia na mancha?',
                'Is there numbness in the lesion?',
              ),
              subtitle: _tr(
                context,
                'Inclui perda de sensibilidade ao toque, frio ou calor.',
                'Includes loss of sensitivity to touch, cold, or heat.',
              ),
              value: hasNumbness,
              onChanged: onNumbnessChanged,
            ),
            const Divider(height: 1),
            _SwitchQuestion(
              title: _tr(
                context,
                'A mancha mudou de cor?',
                'Has the lesion changed color?',
              ),
              subtitle: _tr(
                context,
                'Considere clareamento, avermelhamento ou area mais apagada.',
                'Consider lightening, redness, or a faded-looking area.',
              ),
              value: changedColor,
              onChanged: onColorChanged,
            ),
            const Divider(height: 1),
            _SwitchQuestion(
              title: _tr(
                context,
                'Convive ou conviveu com alguem com hanseniase?',
                'Has the person lived with or closely contacted someone with leprosy?',
              ),
              subtitle: _tr(
                context,
                'Contato domiciliar ou prolongado aumenta o risco epidemiologico.',
                'Household or prolonged contact increases epidemiological risk.',
              ),
              value: hasContactWithConfirmedCase,
              onChanged: onContactChanged,
            ),
            const Divider(height: 1),
            _SwitchQuestion(
              title: _tr(
                context,
                'Sente dor, formigamento ou choque nos nervos?',
                'Is there nerve pain, tingling, or electric-shock sensation?',
              ),
              subtitle: _tr(
                context,
                'Considere cotovelos, joelhos, tornozelos e trajeto dos nervos.',
                'Consider elbows, knees, ankles, and along nerve pathways.',
              ),
              value: hasNervePainOrShock,
              onChanged: onNervePainChanged,
            ),
            const Divider(height: 1),
            _SwitchQuestion(
              title: _tr(
                context,
                'Existe fraqueza para segurar objetos ou levantar o pe?',
                'Is there weakness when holding objects or lifting the foot?',
              ),
              subtitle: _tr(
                context,
                'Fraqueza motora pode indicar comprometimento neural avancado.',
                'Motor weakness may indicate advanced neural involvement.',
              ),
              value: hasMuscleWeakness,
              onChanged: onWeaknessChanged,
            ),
            const Divider(height: 1),
            _SwitchQuestion(
              title: _tr(
                context,
                'A area esta mais seca ou com queda de pelos?',
                'Is the area drier or with hair loss?',
              ),
              subtitle: _tr(
                context,
                'Esse sinal sugere alteracao autonoma associada a dano neural.',
                'This sign suggests autonomic change associated with neural damage.',
              ),
              value: hasDrynessOrHairLoss,
              onChanged: onDrynessChanged,
            ),
            const Divider(height: 1),
            _SwitchQuestion(
              title: _tr(
                context,
                'Existe mais de uma lesao ou mancha suspeita?',
                'Is there more than one suspicious lesion or patch?',
              ),
              subtitle: _tr(
                context,
                'Lesoes multiplas podem aumentar a suspeita quando o padrao se repete.',
                'Multiple lesions can raise suspicion when the pattern repeats.',
              ),
              value: hasMultipleLesions,
              onChanged: onMultipleLesionsChanged,
            ),
            const Divider(height: 1),
            _SwitchQuestion(
              title: _tr(
                context,
                'Ja houve ferida ou queimadura sem sentir dor?',
                'Has there been a wound or burn without pain perception?',
              ),
              subtitle: _tr(
                context,
                'Queimaduras ou machucados sem perceber sugerem perda de sensibilidade importante.',
                'Burns or injuries without noticing them suggest significant sensory loss.',
              ),
              value: hasWoundOrBurnWithoutPain,
              onChanged: onWoundOrBurnChanged,
            ),
            const SizedBox(height: 16),
            Text(
              _tr(context, 'Ha quanto tempo?', 'How long has it been present?'),
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            SegmentedButton<DurationOption>(
              showSelectedIcon: false,
              segments: [
                for (final option in DurationOption.values)
                  ButtonSegment(
                    value: option,
                    label: Text(
                      option.shortLabelFor(language),
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              selected: {duration},
              onSelectionChanged: (selection) {
                onDurationChanged(selection.single);
              },
              style: ButtonStyle(
                shape: WidgetStateProperty.all(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _tr(
                context,
                'Observacoes livres (opcional)',
                'Free notes (optional)',
              ),
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: notesController,
              minLines: 3,
              maxLines: 5,
              onChanged: onNotesChanged,
              decoration: InputDecoration(
                border: OutlineInputBorder(),
                hintText: _tr(
                  context,
                  'Ex.: parece formigamento, esta crescendo rapido, a pele esta ressecada.',
                  'Example: tingling sensation, growing quickly, skin looks dry.',
                ),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: canAnalyze ? () => onAnalyze() : null,
              icon: Icon(
                isAnalyzing ? Icons.hourglass_top : Icons.analytics_outlined,
              ),
              label: Text(
                isAnalyzing
                    ? _tr(
                        context,
                        'Executando no dispositivo...',
                        'Running on device...',
                      )
                    : _tr(
                        context,
                        'Analisar com Gemma 4',
                        'Analyze with Gemma 4',
                      ),
              ),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwitchQuestion extends StatelessWidget {
  const _SwitchQuestion({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }
}

class _EmptyResult extends StatelessWidget {
  const _EmptyResult({required this.modelReady});

  final bool modelReady;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const ValueKey('empty-result'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              Icons.assignment_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                modelReady
                    ? _tr(
                        context,
                        'Selecione uma ou mais imagens, responda as perguntas, registre observacoes se necessario e gere a orientacao de triagem no proprio aparelho.',
                        'Select one or more images, answer the questions, add notes if needed, and generate the triage guidance on the device itself.',
                      )
                    : _tr(
                        context,
                        'O app tenta carregar o Gemma 4 automaticamente; depois selecione uma ou mais imagens e gere a orientacao de triagem.',
                        'The app tries to load Gemma 4 automatically; then select one or more images and generate triage guidance.',
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RunningResult extends StatelessWidget {
  const _RunningResult();

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const ValueKey('running-result'),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              _tr(
                context,
                'Gemma 4 esta processando as imagens, o questionario e as observacoes no dispositivo.',
                'Gemma 4 is processing the images, questionnaire, and notes on the device.',
              ),
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: Color(0xFF173331),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _tr(
                context,
                'Essa etapa pode levar varios segundos na primeira carga do modelo.',
                'This step can take several seconds during the first model load.',
              ),
              style: const TextStyle(height: 1.35, color: Color(0xFF3E5551)),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({required this.result});

  final TriageResult result;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const ValueKey('result-panel'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _RiskBadge(result: result),
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        result.level == RiskLevel.insufficientImage
                            ? _tr(context, 'Revisar', 'Review')
                            : '${result.score}/100',
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF173331),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (result.consistencyNote != null) ...[
              const SizedBox(height: 16),
              _ConsistencyNoteBanner(message: result.consistencyNote!),
            ],
            const SizedBox(height: 16),
            _RiskScoreCards(
              visualTitle: _tr(
                context,
                'Risco visual dermatologico',
                'Dermatologic visual risk',
              ),
              visualScore: result.visualRiskScore,
              visualLevel: result.visualRiskLevel,
              clinicalTitle: _tr(
                context,
                'Risco clinico-neural',
                'Clinical-neural risk',
              ),
              clinicalScore: result.clinicalNeuralRiskScore,
              clinicalLevel: result.clinicalNeuralRiskLevel,
            ),
            if (result.imageQualitySummary.isNotEmpty) ...[
              const SizedBox(height: 16),
              _StructuredListSection(
                icon: Icons.photo_camera_back_outlined,
                title: _tr(context, 'Qualidade das imagens', 'Image quality'),
                items: result.imageQualitySummary,
              ),
            ],
            if (result.regionFindings.isNotEmpty) ...[
              const SizedBox(height: 16),
              _SectionHeader(
                icon: Icons.place_outlined,
                title: _tr(context, 'Achados por regiao', 'Findings by region'),
              ),
              const SizedBox(height: 8),
              for (final finding in result.regionFindings)
                _RegionFindingCard(finding: finding),
            ] else if (result.visualFindings.isNotEmpty) ...[
              const SizedBox(height: 16),
              _StructuredListSection(
                icon: Icons.visibility_outlined,
                title: _tr(context, 'Achados visuais', 'Visual findings'),
                items: result.visualFindings,
              ),
            ],
            if (result.relevantSymptoms.isNotEmpty) ...[
              const SizedBox(height: 16),
              _StructuredListSection(
                icon: Icons.fact_check_outlined,
                title: _tr(context, 'Sintomas relevantes', 'Relevant symptoms'),
                items: result.relevantSymptoms,
              ),
            ],
            if (result.riskFactors.isNotEmpty) ...[
              const SizedBox(height: 16),
              _StructuredListSection(
                icon: Icons.trending_up_outlined,
                title: _tr(
                  context,
                  'Fatores que elevaram o risco',
                  'Factors that raised the risk',
                ),
                items: result.riskFactors,
              ),
            ],
            if (result.confidenceLimitingFactors.isNotEmpty) ...[
              const SizedBox(height: 16),
              _StructuredListSection(
                icon: Icons.error_outline,
                title: _tr(
                  context,
                  'Limites da confianca',
                  'Confidence limitations',
                ),
                items: result.confidenceLimitingFactors,
              ),
            ],
            if (result.reassuringFactors.isNotEmpty) ...[
              const SizedBox(height: 16),
              _StructuredListSection(
                icon: Icons.check_circle_outline,
                title: _tr(
                  context,
                  'Fatores que reduzem a suspeita',
                  'Factors that lower suspicion',
                ),
                items: result.reassuringFactors,
              ),
            ],
            const SizedBox(height: 16),
            _SectionHeader(
              icon: Icons.psychology_alt_outlined,
              title: _tr(context, 'Raciocinio clinico', 'Clinical reasoning'),
            ),
            const SizedBox(height: 8),
            for (final item in result.reasoning) _ReasoningLine(text: item),
            const SizedBox(height: 16),
            _SectionHeader(
              icon: Icons.assignment_late_outlined,
              title: _tr(
                context,
                'Motivo do encaminhamento',
                'Referral reason',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              result.referralReason,
              style: const TextStyle(height: 1.4, color: Color(0xFF314744)),
            ),
            const SizedBox(height: 16),
            _SectionHeader(
              icon: Icons.local_hospital_outlined,
              title: _tr(
                context,
                'Proxima acao para o agente',
                'Next action for the health worker',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              result.nextAction,
              style: const TextStyle(height: 1.4, color: Color(0xFF314744)),
            ),
            const SizedBox(height: 14),
            const _ClinicalSafetyNote(),
          ],
        ),
      ),
    );
  }
}

class _RiskScoreCards extends StatelessWidget {
  const _RiskScoreCards({
    required this.visualTitle,
    required this.visualScore,
    required this.visualLevel,
    required this.clinicalTitle,
    required this.clinicalScore,
    required this.clinicalLevel,
  });

  final String visualTitle;
  final int visualScore;
  final RiskLevel visualLevel;
  final String clinicalTitle;
  final int clinicalScore;
  final RiskLevel clinicalLevel;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 340.0;
        final useTwoColumns = availableWidth >= 560;
        final cardWidth = useTwoColumns
            ? (availableWidth - 12) / 2
            : availableWidth;

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: cardWidth,
              child: _RiskScoreCard(
                title: visualTitle,
                score: visualScore,
                level: visualLevel,
                icon: Icons.visibility_outlined,
              ),
            ),
            SizedBox(
              width: cardWidth,
              child: _RiskScoreCard(
                title: clinicalTitle,
                score: clinicalScore,
                level: clinicalLevel,
                icon: Icons.psychology_alt_outlined,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RiskScoreCard extends StatelessWidget {
  const _RiskScoreCard({
    required this.title,
    required this.score,
    required this.level,
    required this.icon,
  });

  final String title;
  final int score;
  final RiskLevel level;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: level.color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: level.color.withValues(alpha: 0.28)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: level.color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF173331),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    level == RiskLevel.insufficientImage
                        ? level.labelFor(AppLanguageScope.of(context))
                        : '${level.labelFor(AppLanguageScope.of(context))} · $score/100',
                    style: TextStyle(
                      color: level.color,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StructuredListSection extends StatelessWidget {
  const _StructuredListSection({
    required this.icon,
    required this.title,
    required this.items,
  });

  final IconData icon;
  final String title;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(icon: icon, title: title),
        const SizedBox(height: 8),
        for (final item in items) _ReasoningLine(text: item),
      ],
    );
  }
}

class _RegionFindingCard extends StatelessWidget {
  const _RegionFindingCard({required this.finding});

  final RegionFinding finding;

  @override
  Widget build(BuildContext context) {
    final showImageQuality =
        finding.imageQuality.isNotEmpty &&
        _cleanRegionImageQuality(finding.imageQuality) != 'boa';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFF6FAF8),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFDCE5E2)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                finding.region.isEmpty
                    ? _tr(context, 'Regiao avaliada', 'Assessed region')
                    : finding.region,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF173331),
                ),
              ),
              if (showImageQuality) ...[
                const SizedBox(height: 4),
                Text(
                  _localizedImageQualityLabel(context, finding.imageQuality),
                  style: const TextStyle(
                    height: 1.35,
                    color: Color(0xFF5D706C),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              for (final item in finding.findings) _ReasoningLine(text: item),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConsistencyNoteBanner extends StatelessWidget {
  const _ConsistencyNoteBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E0),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE8C785)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.rule_outlined, color: Color(0xFF8A5B00)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(height: 1.35, color: Color(0xFF4F3A12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RiskBadge extends StatelessWidget {
  const _RiskBadge({required this.result});

  final TriageResult result;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: result.level.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: result.level.color.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(result.level.icon, color: result.level.color),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                result.level.labelFor(AppLanguageScope.of(context)),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: result.level.color,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReasoningLine extends StatelessWidget {
  const _ReasoningLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 3),
            child: Icon(Icons.circle, size: 8, color: Color(0xFF126A63)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(height: 1.35, color: Color(0xFF314744)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClinicalSafetyNote extends StatelessWidget {
  const _ClinicalSafetyNote();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E0),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE8C785)),
      ),
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline, color: Color(0xFF8A5B00)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _tr(
                  context,
                  'Sinais neurologicos, feridas, perda de forca ou piora rapida exigem avaliacao presencial. Este resultado nao substitui exame medico.',
                  'Neurological signs, wounds, loss of strength, or rapid worsening require in-person evaluation. This result does not replace a medical exam.',
                ),
                style: const TextStyle(height: 1.35, color: Color(0xFF4F3A12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 22, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Color(0xFF173331),
            ),
          ),
        ),
      ],
    );
  }
}
