package com.example.hansen_guard

import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.LogSeverity
import com.google.ai.edge.litertlm.SamplerConfig
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.text.Normalizer
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/**
 * Android bridge for the offline Gemma 4 E2B LiteRT-LM pipeline.
 *
 * Flutter owns capture UX and result rendering. This activity owns the
 * long-lived Engine instance, multimodal prompt assembly, JSON repair/recovery,
 * and deterministic clinical guardrails before data goes back to Dart.
 */
class MainActivity : FlutterActivity() {
    // Serialize Gemma calls on a single background lane. The LiteRT engine is
    // treated as a stateful resource and is never driven concurrently.
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    // Protects modelEngine and its active configuration during init/analyze/
    // dispose transitions.
    private val engineLock = Any()

    @Volatile
    private var modelEngine: Engine? = null

    @Volatile
    private var activeModelPath: String? = null

    @Volatile
    private var activeBackend: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        ).setMethodCallHandler { call, result ->
            // Keep the channel contract explicit and small: path discovery,
            // engine init, triage execution, and engine disposal.
            when (call.method) {
                "getRecommendedModelPath" -> result.success(getRecommendedModelPath())
                "initializeModel" -> initializeModel(call, result)
                "analyzeTriage" -> analyzeTriage(call, result)
                "disposeModel" -> disposeModel(result)
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        synchronized(engineLock) {
            modelEngine?.close()
            modelEngine = null
        }
        executor.shutdownNow()
        super.onDestroy()
    }

    /**
     * Load or reload the .litertlm artifact on a worker thread and keep the
     * initialized Engine alive for subsequent analyses.
     */
    private fun initializeModel(call: MethodCall, result: MethodChannel.Result) {
        val modelPath = call.argument<String>("modelPath")?.trim().orEmpty()
        val preferredBackend = call.argument<String>("backend")?.trim().orEmpty().ifEmpty { "gpu" }

        if (modelPath.isEmpty()) {
            result.error("missing_model_path", "Informe o caminho do arquivo .litertlm.", null)
            return
        }

        executor.execute {
            try {
                val initResult = synchronized(engineLock) {
                    initializeEngine(modelPath = modelPath, preferredBackend = preferredBackend)
                }

                respondSuccess(
                    result,
                    mapOf(
                        "modelPath" to initResult.modelPath,
                        "backend" to initResult.backend,
                        "message" to initResult.message,
                    ),
                )
            } catch (exception: Exception) {
                respondError(result, "init_failed", exception.message ?: "Falha ao inicializar o LiteRT-LM.")
            }
        }
    }

    /**
     * Execute one end-to-end offline screening pass: collect inputs from
     * Flutter, build the multimodal prompt, run Gemma, repair/parse JSON, and
     * finally apply deterministic guardrails before returning a wire payload.
     */
    private fun analyzeTriage(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val currentEngine = synchronized(engineLock) {
                    modelEngine
                } ?: throw IllegalStateException(
                    "Modelo nao inicializado. Inicialize o Gemma 4 no Android antes da analise.",
                )

                val receivedImageBytesList = call.argument<List<ByteArray>>("imageBytesList")
                    ?.filter { it.isNotEmpty() }
                    .orEmpty()
                    .ifEmpty {
                        call.argument<ByteArray>("imageBytes")?.let(::listOf)
                            ?: throw IllegalArgumentException("Nenhuma imagem de lesao foi recebida.")
                    }
                // Keep multimodal payloads inside the context budget that the
                // local Gemma configuration handles reliably on device.
                if (receivedImageBytesList.size > MAX_ANALYSIS_IMAGES) {
                    throw IllegalArgumentException(
                        "O protocolo aceita ate $MAX_ANALYSIS_IMAGES fotos por analise no Gemma 4 offline.",
                    )
                }
                val imageBytesList = receivedImageBytesList
                val imageLabels = call.stringListArgument("imageLabels")
                    .take(imageBytesList.size)
                val imageQualityNotes = call.stringListArgument("imageQualityNotes")
                    .take(imageBytesList.size)
                val languageCode = call.argument<String>("languageCode")
                    ?.trim()
                    ?.lowercase()
                    ?.takeIf { it == "en" }
                    ?: "pt"

                val clinicalSignals = ClinicalSignals(
                    hasNumbness = call.argument<Boolean>("hasNumbness") ?: false,
                    changedColor = call.argument<Boolean>("changedColor") ?: false,
                    hasContactWithConfirmedCase = call.argument<Boolean>("hasContactWithConfirmedCase") ?: false,
                    hasNervePainOrShock = call.argument<Boolean>("hasNervePainOrShock") ?: false,
                    hasMuscleWeakness = call.argument<Boolean>("hasMuscleWeakness") ?: false,
                    hasDrynessOrHairLoss = call.argument<Boolean>("hasDrynessOrHairLoss") ?: false,
                    hasMultipleLesions = call.argument<Boolean>("hasMultipleLesions") ?: false,
                    hasWoundOrBurnWithoutPain = call.argument<Boolean>("hasWoundOrBurnWithoutPain") ?: false,
                    durationLabel = call.argument<String>("durationLabel").orEmpty(),
                    notes = call.argument<String>("notes")?.trim().orEmpty(),
                )

                val prompt = buildPrompt(
                    caseName = call.argument<String>("caseName").orEmpty(),
                    region = call.argument<String>("region").orEmpty(),
                    visualSummary = call.argument<String>("visualSummary").orEmpty(),
                    imageCount = imageBytesList.size,
                    imageLabels = imageLabels,
                    imageQualityNotes = imageQualityNotes,
                    clinicalSignals = clinicalSignals,
                    languageCode = languageCode,
                )

                val contents = buildList<Content> {
                    // Images are sent first so the final text prompt can refer
                    // to the whole protocol as one case.
                    imageBytesList.forEach { add(Content.ImageBytes(it)) }
                    add(Content.Text(prompt))
                }

                val responseText = runGemma(currentEngine, contents, languageCode)
                val parsed = parseModelResponseWithRetry(currentEngine, responseText, languageCode)
                val calibrated = applyClinicalGuardrails(parsed, clinicalSignals, languageCode)
                respondSuccess(result, calibrated.toWireMap())
            } catch (exception: Exception) {
                respondError(result, "analysis_failed", friendlyAnalysisError(exception))
            }
        }
    }

    /**
     * Free the native engine explicitly so a later session can rebuild it with
     * a different backend or model file without carrying stale state.
     */
    private fun disposeModel(result: MethodChannel.Result) {
        executor.execute {
            synchronized(engineLock) {
                modelEngine?.close()
                modelEngine = null
                activeModelPath = null
                activeBackend = null
            }
            respondSuccess(result, null)
        }
    }

    // Return the app-scoped external-files path that the helper scripts also
    // target when pushing the model over ADB.
    private fun getRecommendedModelPath(): String {
        val baseDir = getExternalFilesDir(null) ?: filesDir
        return File(baseDir, DEFAULT_MODEL_FILENAME).absolutePath
    }

    /**
     * Validate the requested model path, reuse an existing engine when nothing
     * changed, and fall back from GPU to CPU when the device cannot allocate
     * the preferred backend.
     */
    private fun initializeEngine(
        modelPath: String,
        preferredBackend: String,
    ): InitializationOutcome {
        val normalizedModelPath = normalizeModelPath(modelPath)
        val modelFile = File(normalizedModelPath)
        if (!modelFile.exists()) {
            val recommendedPath = getRecommendedModelPath()
            val typoHint = if (normalizedModelPath != modelPath) {
                " O caminho informado parece ter um typo: $modelPath"
            } else {
                ""
            }
            throw IllegalStateException(
                "Arquivo .litertlm nao encontrado em: $normalizedModelPath.$typoHint Se o app foi reinstalado ou atualizado, envie o modelo novamente para: $recommendedPath",
            )
        }
        if (!modelFile.canRead()) {
            throw IllegalStateException("O app nao conseguiu ler o modelo em: $normalizedModelPath")
        }

        if (activeModelPath == normalizedModelPath && activeBackend == preferredBackend && modelEngine != null) {
            return InitializationOutcome(
                modelPath = normalizedModelPath,
                backend = preferredBackend,
                message = "Gemma 4 ja estava inicializado em ${preferredBackend.uppercase()}.",
            )
        }

        modelEngine?.close()
        modelEngine = null

        Engine.setNativeMinLogSeverity(LogSeverity.ERROR)

        return try {
            val configuredEngine = createEngine(normalizedModelPath, preferredBackend)
            modelEngine = configuredEngine
            activeModelPath = normalizedModelPath
            activeBackend = preferredBackend
            InitializationOutcome(
                modelPath = normalizedModelPath,
                backend = preferredBackend,
                message = "Gemma 4 inicializado em ${preferredBackend.uppercase()} no dispositivo.",
            )
        } catch (gpuError: Exception) {
            if (preferredBackend != "gpu") {
                throw gpuError
            }

            val configuredEngine = createEngine(normalizedModelPath, "cpu")
            modelEngine = configuredEngine
            activeModelPath = normalizedModelPath
            activeBackend = "cpu"
            InitializationOutcome(
                modelPath = normalizedModelPath,
                backend = "cpu",
                message = "GPU indisponivel neste aparelho. Gemma 4 inicializado em CPU.",
            )
        }
    }

    // Repair a common typo seen in manually typed storage paths.
    private fun normalizeModelPath(modelPath: String): String {
        return modelPath
            .replace("/storage/emulaled/", "/storage/emulated/")
            .replace("/storage/emulaled", "/storage/emulated")
    }

    // Build the LiteRT engine with a shared backend for text and vision.
    private fun createEngine(modelPath: String, backendWire: String): Engine {
        val backend = backendFromWire(backendWire)
        val config = EngineConfig(
            modelPath = modelPath,
            backend = backend,
            visionBackend = backend,
            cacheDir = cacheDir.absolutePath,
        )
        return Engine(config).also { it.initialize() }
    }

    // Keep the system prompt language-specific while preserving the same output
    // contract for the structured triage JSON.
    private fun systemPromptFor(languageCode: String): String {
        return if (languageCode == "en") {
            """
            You support offline community screening for leprosy. Do not diagnose or replace clinical evaluation.
            Always answer with valid compact JSON, no markdown.
            All user-visible string values must be in English.
            Compare images as one case and group findings by region.
            Separate dermatologic visual risk from clinical-neural risk.
            Use "insufficient_image" only when no skin or lesion is visually assessable.
            Low resolution or blur reduces confidence, but must not zero visual risk when visible findings exist.
            Calibration: numbness/contact/long duration raise clinical risk; persistent patch/plaque with color difference raises visual risk; dark images with no assessable skin generate insufficient_image.
            """.trimIndent()
        } else {
            SYSTEM_PROMPT
        }
    }

    // Conservative sampler settings reduce response drift and make JSON repair
    // less necessary on-device.
    private fun conversationConfig(languageCode: String = "pt"): ConversationConfig {
        return ConversationConfig(
            systemInstruction = Contents.of(systemPromptFor(languageCode)),
            samplerConfig = SamplerConfig(
                topK = 20,
                topP = 0.9,
                temperature = 0.2,
            ),
        )
    }

    // One Gemma conversation per request keeps prompts isolated between cases.
    private fun runGemma(engine: Engine, contents: List<Content>, languageCode: String = "pt"): String {
        return engine.createConversation(conversationConfig(languageCode)).use { conversation ->
            conversation.sendMessage(
                Contents.of(*contents.toTypedArray()),
            ).toString()
        }
    }

    /**
     * First try to parse the model output as structured JSON. If formatting is
     * broken, ask Gemma for a local repair pass before falling back to salvage
     * heuristics that preserve clinically useful fragments.
     */
    private fun parseModelResponseWithRetry(
        engine: Engine,
        responseText: String,
        languageCode: String,
    ): ModelResponse {
        return try {
            parseModelResponse(responseText)
        } catch (exception: ModelJsonException) {
            val repairPrompt = buildJsonRepairPrompt(
                invalidResponse = exception.rawResponse,
                parseError = exception.message ?: "JSON invalido",
                languageCode = languageCode,
            )
            val repairedResponse = try {
                runGemma(engine, listOf(Content.Text(repairPrompt)), languageCode)
            } catch (repairRunException: Exception) {
                buildSalvagedModelResponse(exception.rawResponse, languageCode)?.let {
                    return it
                }
                return buildFallbackModelResponse(
                    parseError = repairRunException.message ?: "Falha ao reparar JSON localmente.",
                    languageCode = languageCode,
                )
            }

            try {
                parseModelResponse(repairedResponse)
            } catch (repairException: ModelJsonException) {
                buildSalvagedModelResponse(repairedResponse, languageCode)
                    ?: buildSalvagedModelResponse(exception.rawResponse, languageCode)
                    ?: buildFallbackModelResponse(
                        parseError = repairException.message ?: "JSON reparado ainda invalido.",
                        languageCode = languageCode,
                    )
            }
        }
    }

    // Secondary prompt used only when the first pass returned malformed JSON.
    private fun buildJsonRepairPrompt(
        invalidResponse: String,
        parseError: String,
        languageCode: String,
    ): String {
        val clippedResponse = invalidResponse.take(MAX_REPAIR_RESPONSE_CHARS)
        val languageInstruction = if (languageCode == "en") {
            "Write every user-visible string value in English."
        } else {
            "Escreva todos os textos exibidos ao usuario em portugues do Brasil."
        }
        return """
Converta a resposta abaixo para JSON valido, completo e estritamente compativel com o schema de triagem.
Nao adicione markdown, comentarios, texto antes ou depois do JSON.
$languageInstruction
Preserve o sentido clinico original quando possivel.
Se algum texto estiver cortado, complete com uma frase clinica curta ou remova o fragmento.
Nunca copie palavras truncadas, abreviacoes com "/" ou frases inacabadas.
Se houver achados visuais aproveitaveis, nao use insufficient_image apenas por erro de JSON.
Se algum campo estiver ausente, preencha com lista vazia, texto curto seguro ou score coerente com os achados.

Erro local ao validar: $parseError

Schema obrigatorio:
{
  "image_quality_summary": [],
  "region_findings": [
    {"region": "Regiao 1", "image_quality": "boa|limitada|insuficiente", "findings": []}
  ],
  "relevant_symptoms": [],
  "visual_risk_level": "low|moderate|high|insufficient_image",
  "visual_risk_score": 0,
  "clinical_neural_risk_level": "low|moderate|high",
  "clinical_neural_risk_score": 0,
  "risk_level": "low|moderate|high|insufficient_image",
  "score": 0,
  "risk_increasing_factors": [],
  "confidence_limiting_factors": [],
  "reassuring_factors": [],
  "referral_reason": "",
  "next_action": "",
  "reasoning": []
}

Resposta original:
$clippedResponse
""".trimIndent()
    }

    // If both JSON passes are malformed, salvage the most useful structured
    // fragments instead of discarding visible findings outright.
    private fun buildSalvagedModelResponse(responseText: String, languageCode: String = "pt"): ModelResponse? {
        val visualFindings = (
            extractStringArray(responseText, "visual_findings", limit = 4) +
                extractVisualSentences(responseText)
            )
            .distinct()
            .take(4)
        val regionFindings = extractRegionFindings(responseText).ifEmpty {
            if (visualFindings.isEmpty()) {
                emptyList()
            } else {
                listOf(
                    RegionFinding(
                        region = pick(languageCode, "Regiao avaliada", "Assessed region"),
                        imageQuality = extractStringValue(responseText, "image_quality").ifBlank { "limitada" },
                        findings = visualFindings,
                    ),
                )
            }
        }
            // Map raw engine errors to messages that tell the field user what to change.
        val imageQualitySummary = extractStringArray(responseText, "image_quality_summary", limit = 3)
        val reasoning = extractStringArray(responseText, "reasoning", limit = 3).ifEmpty {
            visualFindings.take(2).map { "Achado visual recuperado da resposta local: $it" }
        }

        val hasUsefulVisualContent = visualFindings.isNotEmpty() || regionFindings.any { it.findings.isNotEmpty() }
        val hasAnyUsefulContent = hasUsefulVisualContent ||
            imageQualitySummary.isNotEmpty() ||
            reasoning.isNotEmpty() ||
            extractStringValue(responseText, "referral_reason").isNotBlank() ||
            extractStringValue(responseText, "next_action").isNotBlank()

        if (!hasAnyUsefulContent) {
            return null
        }

        val visualScore = extractIntValue(responseText, "visual_risk_score")
            ?: extractIntValue(responseText, "score")
            ?: if (hasUsefulVisualContent) 30 else 0
        val score = extractIntValue(responseText, "score") ?: visualScore
        val visualLevel = normalizeRiskLevel(
            extractStringValue(responseText, "visual_risk_level").ifBlank {
                if (hasUsefulVisualContent) scoreToRiskLevel(visualScore) else INSUFFICIENT_IMAGE_LEVEL
            },
        )
        val riskLevel = normalizeRiskLevel(
            extractStringValue(responseText, "risk_level").ifBlank {
                if (hasUsefulVisualContent) scoreToRiskLevel(score) else INSUFFICIENT_IMAGE_LEVEL
            },
        )
        val clinicalScore = extractIntValue(responseText, "clinical_neural_risk_score")
            ?: extractIntValue(responseText, "clinical_risk_score")
            ?: 0

        return ModelResponse(
            score = score.coerceIn(0, 100),
            riskLevel = riskLevel,
            imageQualitySummary = imageQualitySummary.ifEmpty {
                listOf(
                    pick(
                        languageCode,
                        "Resposta local parcialmente recuperada; revisar achados e fatores de confianca.",
                        "Local response partially recovered; review findings and confidence factors.",
                    ),
                )
            },
            regionFindings = regionFindings,
            visualFindings = visualFindings,
            visualRiskScore = visualScore.coerceIn(0, 100),
            visualRiskLevel = visualLevel,
            clinicalNeuralRiskScore = clinicalScore.coerceIn(0, 100),
            clinicalNeuralRiskLevel = normalizeRiskLevel(
                extractStringValue(responseText, "clinical_neural_risk_level").ifBlank {
                    scoreToRiskLevel(clinicalScore)
                },
            ),
            relevantSymptoms = extractStringArray(responseText, "relevant_symptoms", limit = 3),
            riskFactors = extractStringArray(responseText, "risk_increasing_factors", limit = 4),
            confidenceLimitingFactors = (
                extractStringArray(responseText, "confidence_limiting_factors", limit = 3) +
                    pick(languageCode, "resposta local parcialmente recuperada", "local response partially recovered")
                ).distinct().take(3),
            reassuringFactors = extractStringArray(responseText, "reassuring_factors", limit = 3),
            reasoning = reasoning.ifEmpty {
                listOf(
                    pick(
                        languageCode,
                        "A resposta local foi recuperada parcialmente para preservar a triagem visual.",
                        "The local response was partially recovered to preserve visual screening.",
                    ),
                )
            },
            referralReason = extractStringValue(responseText, "referral_reason").ifBlank {
                pick(
                    languageCode,
                    "Prioridade definida pelos achados visuais recuperados e sinais informados.",
                    "Priority defined by recovered visual findings and reported signs.",
                )
            },
            nextAction = extractStringValue(responseText, "next_action").ifBlank {
                pick(
                    languageCode,
                    "Revisar os achados e considerar avaliacao presencial se houver persistencia, dormencia, progressao ou contato confirmado.",
                    "Review the findings and consider in-person evaluation if there is persistence, numbness, progression, or confirmed contact.",
                )
            },
        )
    }

    private fun buildFallbackModelResponse(parseError: String, languageCode: String = "pt"): ModelResponse {
        return ModelResponse(
            score = 0,
            riskLevel = INSUFFICIENT_IMAGE_LEVEL,
            imageQualitySummary = listOf(
                pick(
                    languageCode,
                    "Nao foi possivel obter uma resposta estruturada do Gemma 4 nesta tentativa.",
                    "Gemma 4 did not return a structured response in this attempt.",
                ),
            ),
            regionFindings = emptyList(),
            visualFindings = emptyList(),
            visualRiskScore = 0,
            visualRiskLevel = INSUFFICIENT_IMAGE_LEVEL,
            clinicalNeuralRiskScore = 0,
            clinicalNeuralRiskLevel = "low",
            relevantSymptoms = emptyList(),
            riskFactors = emptyList(),
            confidenceLimitingFactors = listOf(
                pick(languageCode, "resposta local incompleta do Gemma 4 nesta tentativa", "incomplete local Gemma 4 response in this attempt"),
                pick(languageCode, "triagem visual nao consolidada; execute a analise novamente", "visual screening was not consolidated; run the analysis again"),
            ),
            reassuringFactors = emptyList(),
            reasoning = listOf(
                pick(languageCode, "A resposta local nao ficou estruturada o suficiente para uma triagem segura.", "The local response was not structured enough for safe screening."),
                pick(languageCode, "Para evitar conclusao indevida, esta tentativa foi marcada como insuficiente.", "To avoid an unsupported conclusion, this attempt was marked as insufficient."),
            ),
            referralReason = pick(languageCode, "Sem resposta estruturada suficiente para apoiar a triagem nesta tentativa.", "There was not enough structured response to support screening in this attempt."),
            nextAction = pick(languageCode, "Tentar executar a analise novamente; se persistir, refazer as fotos do protocolo com boa luz, foco e lesao centralizada.", "Run the analysis again; if it persists, retake protocol photos with good light, focus, and centered lesion."),
            consistencyNote = null,
        )
    }

    private fun extractIntValue(text: String, key: String): Int? {
        val pattern = Regex("\"$key\"\\s*:\\s*(\\d{1,3})")
        return pattern.find(text)?.groupValues?.getOrNull(1)?.toIntOrNull()?.coerceIn(0, 100)
    }

    private fun extractStringValue(text: String, key: String): String {
        val pattern = Regex("\"$key\"\\s*:\\s*\"([^\"]*)\"", RegexOption.DOT_MATCHES_ALL)
        return pattern.find(text)?.groupValues?.getOrNull(1)?.trim().orEmpty()
    }

    private fun extractStringArray(text: String, key: String, limit: Int = 4): List<String> {
        val pattern = Regex("\"$key\"\\s*:\\s*\\[(.*?)]", RegexOption.DOT_MATCHES_ALL)
        val block = pattern.find(text)?.groupValues?.getOrNull(1).orEmpty()
        if (block.isBlank()) {
            return emptyList()
        }

        return Regex("\"([^\"]{3,260})\"")
            .findAll(block)
            .map { cleanModelText(it.groupValues[1]) }
            .filter { it.isNotEmpty() }
            .take(limit)
            .toList()
    }

    private fun extractRegionFindings(text: String): List<RegionFinding> {
        val pattern = Regex(
            "\\{\\s*\"region\"\\s*:\\s*\"([^\"]*)\"\\s*,\\s*\"image_quality\"\\s*:\\s*\"([^\"]*)\"\\s*,\\s*\"findings\"\\s*:\\s*\\[(.*?)]",
            RegexOption.DOT_MATCHES_ALL,
        )
        return pattern.findAll(text)
            .mapNotNull { match ->
                val findings = Regex("\"([^\"]{3,260})\"")
                    .findAll(match.groupValues[3])
                    .map { cleanModelText(it.groupValues[1]) }
                    .filter { it.isNotEmpty() }
                    .take(4)
                    .toList()
                val region = match.groupValues[1].trim().ifBlank { "Regiao avaliada" }
                val quality = match.groupValues[2].trim().ifBlank { "limitada" }
                if (findings.isEmpty() && quality.isBlank()) {
                    null
                } else {
                    RegionFinding(region = region, imageQuality = quality, findings = findings)
                }
            }
            .take(3)
            .toList()
    }

    private fun extractVisualSentences(text: String): List<String> {
        val visualTerms = listOf(
            "lesao",
            "lesoes",
            "mancha",
            "placa",
            "eritem",
            "vermelh",
            "hipocrom",
            "hipercrom",
            "hiperpigment",
            "textura",
            "borda",
            "alteracao cutanea",
            "diferenca de cor",
            "lesion",
            "patch",
            "plaque",
            "erythema",
            "redness",
            "hypopig",
            "hyperpig",
            "texture",
            "border",
            "skin change",
            "color difference",
        )
        return text
            .replace("{", " ")
            .replace("}", " ")
            .split(Regex("[\\n.;]"))
            .map { cleanModelText(it.trim().trim('"', ',', '[', ']')) }
            .filter { sentence ->
                val normalized = normalizeText(sentence)
                sentence.length in 12..320 &&
                    visualTerms.any(normalized::contains) &&
                    !normalized.contains("schema obrigatorio") &&
                    !normalized.contains("risk_level") &&
                    !normalized.contains("visual_risk")
            }
            .distinct()
            .take(4)
    }

    private fun cleanModelText(text: String): String {
        var cleaned = text
            .trim()
            .trim('"', ',', '[', ']')
            .replace("\\s+".toRegex(), " ")
            .replace("/\\S{1,16}$".toRegex(), "")
            .trim()
        val normalized = normalizeText(cleaned)
        val incompleteEnding = listOf(
            " de",
            " da",
            " do",
            " das",
            " dos",
            " em",
            " com",
            " por",
            " para",
            " e",
            " ou",
            "/",
            ":",
            "-",
        ).any { normalized.endsWith(it) }

        if (cleaned.length < 8 || incompleteEnding) {
            return ""
        }

        if (!cleaned.endsWith(".") && !cleaned.endsWith(")") && !cleaned.endsWith("%")) {
            cleaned += "."
        }
        return cleaned
    }

    private fun friendlyAnalysisError(exception: Exception): String {
        val rawMessage = exception.message ?: "Falha na analise com Gemma 4."
        val normalized = normalizeText(rawMessage)
        return if (
            normalized.contains("input token") ||
            normalized.contains("maximum number of tokens") ||
            normalized.contains("too long") ||
            normalized.contains("4096")
        ) {
            "O conjunto de fotos ficou grande para a janela local do Gemma 4. Use no maximo 6 fotos, priorizando foto geral, media e proxima; se precisar avaliar outra area, remova a comparacao opcional ou analise a regiao em outro atendimento."
        } else {
            rawMessage
        }
    }

    private fun MethodCall.stringListArgument(name: String): List<String> {
        return argument<List<Any?>>(name)
            ?.mapNotNull { item -> item?.toString()?.trim()?.takeIf { it.isNotEmpty() } }
            .orEmpty()
    }

    // Echo the local photo protocol into text so Gemma can compare regions,
    // capture distance, and quality notes across the full case.
    private fun buildImageProtocolSummary(
        imageCount: Int,
        imageLabels: List<String>,
        imageQualityNotes: List<String>,
    ): String {
        return (0 until imageCount).joinToString("\n") { index ->
            val label = imageLabels.getOrNull(index) ?: "Imagem ${index + 1} sem rotulo"
            val quality = imageQualityNotes.getOrNull(index) ?: "sem validacao local informada"
            "- Imagem ${index + 1}: $label; qualidade: $quality"
        }
    }

    /**
     * Build the textual part of the multimodal prompt. The prompt explicitly
     * separates visual interpretation from clinical-neural signals so later
     * guardrails can lift unsafe underestimates without hiding visible findings.
     */
    private fun buildPrompt(
        caseName: String,
        region: String,
        visualSummary: String,
        imageCount: Int,
        imageLabels: List<String>,
        imageQualityNotes: List<String>,
        clinicalSignals: ClinicalSignals,
        languageCode: String,
    ): String {
        fun yesNo(value: Boolean): String {
            return if (languageCode == "en") {
                if (value) "yes" else "no"
            } else {
                if (value) "sim" else "nao"
            }
        }

        val numbnessLabel = yesNo(clinicalSignals.hasNumbness)
        val colorLabel = yesNo(clinicalSignals.changedColor)
        val contactLabel = yesNo(clinicalSignals.hasContactWithConfirmedCase)
        val nervePainLabel = yesNo(clinicalSignals.hasNervePainOrShock)
        val weaknessLabel = yesNo(clinicalSignals.hasMuscleWeakness)
        val drynessLabel = yesNo(clinicalSignals.hasDrynessOrHairLoss)
        val multipleLesionsLabel = yesNo(clinicalSignals.hasMultipleLesions)
        val woundOrBurnLabel = yesNo(clinicalSignals.hasWoundOrBurnWithoutPain)
        val notesLabel = clinicalSignals.notes.ifBlank {
            pick(languageCode, "nenhuma observacao adicional", "no additional notes")
        }
        val imageProtocolSummary = buildImageProtocolSummary(
            imageCount = imageCount,
            imageLabels = imageLabels,
            imageQualityNotes = imageQualityNotes,
        )
        if (languageCode == "en") {
            return """
Offline leprosy screening. Return only valid compact JSON.
Output language: English. All user-visible string values must be written in English.

Case: $caseName
Source: $region
Summary: $visualSummary
Images received: $imageCount
$imageProtocolSummary

Interview:
- numbness: $numbnessLabel
- color change: $colorLabel
- confirmed contact: $contactLabel
- nerve pain/tingling/electric shock: $nervePainLabel
- muscle weakness: $weaknessLabel
- dryness/hair loss: $drynessLabel
- more than one lesion/patch: $multipleLesionsLabel
- painless wound/burn: $woundOrBurnLabel
- duration: ${clinicalSignals.durationLabel}
- notes: $notesLabel

Rules:
- Do not diagnose; indicate screening priority.
- Group findings by region using the image labels.
- In region_findings, write 2 to 3 complete findings per region when skin is assessable: color, borders/distribution, texture, and comparison across photos.
- image_quality must be exactly one of: "good", "limited", "insufficient".
- Low resolution/blur/shake reduce confidence, but do not prevent scoring when skin or lesion is assessable.
- Use insufficient_image only when there is no assessable visual content.
- Separate dermatologic visual risk from clinical-neural risk.
- risk_increasing_factors: only factors that raise risk; absences and poor image quality go in reassuring/confidence.
- Do not copy option strings with "|"; choose a single real value.
- Do not use slashes, abbreviations, or truncated words. Every string must be a complete sentence.
- If the answer must be short, prioritize region_findings, visual_risk_level, visual_risk_score, risk_level, score, and next_action.
- Arrays may have up to 4 items; visual findings should be objective but not truncated.

Required JSON:
{"image_quality_summary":[],"region_findings":[{"region":"Region 1","image_quality":"good|limited|insufficient","findings":[]}],"relevant_symptoms":[],"visual_risk_level":"low|moderate|high|insufficient_image","visual_risk_score":0,"clinical_neural_risk_level":"low|moderate|high","clinical_neural_risk_score":0,"risk_level":"low|moderate|high|insufficient_image","score":0,"risk_increasing_factors":[],"confidence_limiting_factors":[],"reassuring_factors":[],"referral_reason":"","next_action":"","reasoning":[]}
""".trimIndent()
        }

        return """
Triagem offline de hanseniase. Retorne somente JSON valido e compacto.
Idioma da resposta: portugues do Brasil. Todos os textos exibidos ao usuario devem estar em portugues.

Caso: $caseName
Origem: $region
Resumo: $visualSummary
Fotos recebidas: $imageCount
$imageProtocolSummary

Entrevista:
- dormencia: $numbnessLabel
- mudanca de cor: $colorLabel
- contato confirmado: $contactLabel
- dor/formigamento/choque em nervos: $nervePainLabel
- fraqueza muscular: $weaknessLabel
- ressecamento/queda de pelos: $drynessLabel
- mais de uma lesao/mancha: $multipleLesionsLabel
- ferida/queimadura sem sentir: $woundOrBurnLabel
- duracao: ${clinicalSignals.durationLabel}
- observacoes: $notesLabel

Regras:
- Nao diagnostique; indique prioridade de triagem.
- Avalie achados por regiao usando os rotulos das fotos.
- Em region_findings, escreva 2 a 3 achados completos por regiao quando houver pele avaliavel: cor, bordas/distribuicao, textura e comparacao entre fotos.
- image_quality deve ser apenas "boa", "limitada" ou "insuficiente".
- Baixa resolucao/desfoque/tremor reduzem confianca, mas nao impedem score se houver pele ou lesao avaliavel.
- Use insufficient_image somente se nao houver conteudo visual avaliavel.
- Separe risco visual dermatologico de risco clinico-neural.
- risk_increasing_factors: apenas fatores que elevam risco; ausencias e imagem ruim vao em reassuring/confidence.
- Nao copie as opcoes com "|"; escolha um unico valor real para cada campo.
- Nao use barras, abreviacoes ou palavras cortadas. Cada string deve ser uma frase completa.
- Se a resposta precisar ser curta, priorize region_findings, visual_risk_level, visual_risk_score, risk_level, score e next_action.
- Arrays com no maximo 4 itens; achados visuais em frases objetivas, mas nao truncadas.

JSON obrigatorio:
{"image_quality_summary":[],"region_findings":[{"region":"Regiao 1","image_quality":"boa|limitada|insuficiente","findings":[]}],"relevant_symptoms":[],"visual_risk_level":"low|moderate|high|insufficient_image","visual_risk_score":0,"clinical_neural_risk_level":"low|moderate|high","clinical_neural_risk_score":0,"risk_level":"low|moderate|high|insufficient_image","score":0,"risk_increasing_factors":[],"confidence_limiting_factors":[],"reassuring_factors":[],"referral_reason":"","next_action":"","reasoning":[]}
""".trimIndent()
    }

    private fun parseModelResponse(responseText: String): ModelResponse {
        val cleaned = extractJsonBlock(responseText)
        try {
            val json = JSONObject(cleaned)
            validateStructuredTriageJson(json, responseText)
            val score = json.optInt("score", 0).coerceIn(0, 100)
            val level = json.optString("risk_level", "").ifBlank {
                scoreToRiskLevel(score)
            }
            val imageQualitySummary = json.optJSONArray("image_quality_summary").toStringList()
            val regionFindings = json.optJSONArray("region_findings").toRegionFindings()
            val visualFindings = json.optJSONArray("visual_findings").toStringList()
                .ifEmpty { regionFindings.flatMap { it.findings } }
            val visualRiskScore = json.optInt("visual_risk_score", score).coerceIn(0, 100)
            val clinicalNeuralRiskScore = json.optInt(
                "clinical_neural_risk_score",
                json.optInt("clinical_risk_score", score),
            ).coerceIn(0, 100)
            val visualRiskLevel = normalizeRiskLevel(
                json.optString("visual_risk_level", "").ifBlank {
                    scoreToRiskLevel(visualRiskScore)
                },
            )
            val clinicalNeuralRiskLevel = normalizeRiskLevel(
                json.optString("clinical_neural_risk_level", json.optString("clinical_risk_level", "")).ifBlank {
                    scoreToRiskLevel(clinicalNeuralRiskScore)
                },
            )
            val relevantSymptoms = json.optJSONArray("relevant_symptoms").toStringList()
            val riskFactors = json.optJSONArray("risk_increasing_factors").toStringList()
                .ifEmpty { json.optJSONArray("risk_factors").toStringList() }
            val confidenceLimitingFactors = json.optJSONArray("confidence_limiting_factors").toStringList()
            val reassuringFactors = json.optJSONArray("reassuring_factors").toStringList()
            val reasoning = (json.optJSONArray("reasoning") ?: JSONArray()).toStringList()

            val nextAction = json.optString(
                "next_action",
                json.optString("recommended_action", ""),
            ).trim()
            val referralReason = json.optString("referral_reason", "").trim()

            return ModelResponse(
                score = score,
                riskLevel = normalizeRiskLevel(level),
                imageQualitySummary = imageQualitySummary,
                regionFindings = regionFindings,
                visualFindings = visualFindings,
                visualRiskScore = visualRiskScore,
                visualRiskLevel = visualRiskLevel,
                clinicalNeuralRiskScore = clinicalNeuralRiskScore,
                clinicalNeuralRiskLevel = clinicalNeuralRiskLevel,
                relevantSymptoms = relevantSymptoms,
                riskFactors = riskFactors,
                confidenceLimitingFactors = confidenceLimitingFactors,
                reassuringFactors = reassuringFactors,
                reasoning = reasoning,
                referralReason = referralReason,
                nextAction = nextAction,
            )
        } catch (exception: JSONException) {
            throw ModelJsonException(
                message = "O modelo respondeu fora do JSON esperado: ${exception.message}",
                rawResponse = responseText,
            )
        }
    }

    private fun validateStructuredTriageJson(json: JSONObject, rawResponse: String) {
        val hasRisk = json.has("risk_level") || json.has("riskLevel")
        val hasScore = json.has("score")

        if (!hasRisk || !hasScore) {
            throw ModelJsonException(
                message = "JSON sem campos obrigatorios de triagem.",
                rawResponse = rawResponse,
            )
        }

        val referralReason = json.optString("referral_reason", "").trim()
        val reasoning = json.optJSONArray("reasoning").toStringList()
        val imageQualitySummary = json.optJSONArray("image_quality_summary").toStringList()
        val regionFindings = json.optJSONArray("region_findings").toRegionFindings()
        val hasRegionContent = regionFindings.any { finding ->
            finding.imageQuality.isNotBlank() || finding.findings.isNotEmpty()
        }
        val hasMeaningfulContent = reasoning.isNotEmpty() ||
            referralReason.isNotBlank() ||
            imageQualitySummary.isNotEmpty() ||
            hasRegionContent

        if (!hasMeaningfulContent) {
            throw ModelJsonException(
                message = "JSON sem conteudo clinico suficiente.",
                rawResponse = rawResponse,
            )
        }
    }

    /**
     * Gemma is responsible for visual interpretation. This layer adds a
     * deterministic floor for high-signal clinical answers so under-triage is
     * less likely when neurologic or exposure clues are present.
     */
    private fun applyClinicalGuardrails(
        response: ModelResponse,
        clinicalSignals: ClinicalSignals,
        languageCode: String = "pt",
    ): ModelResponse {
        val alertFactors = mutableListOf<String>()
        var signalPoints = 0

        if (clinicalSignals.hasNumbness) {
            signalPoints += 28
            alertFactors += pick(languageCode, "dormencia", "reported numbness")
        }
        if (clinicalSignals.hasNervePainOrShock) {
            signalPoints += 20
            alertFactors += pick(languageCode, "dor ou choque em nervos", "nerve pain or electric shock sensation")
        }
        if (clinicalSignals.hasMuscleWeakness) {
            signalPoints += 26
            alertFactors += pick(languageCode, "fraqueza muscular", "muscle weakness")
        }
        if (clinicalSignals.hasContactWithConfirmedCase) {
            signalPoints += 16
            alertFactors += pick(languageCode, "contato com caso confirmado", "contact with a confirmed case")
        }
        if (clinicalSignals.hasDrynessOrHairLoss) {
            signalPoints += 10
            alertFactors += pick(languageCode, "ressecamento ou queda de pelos", "dry skin or hair loss")
        }
        if (clinicalSignals.hasMultipleLesions) {
            signalPoints += 12
            alertFactors += pick(languageCode, "mais de uma lesao", "more than one lesion")
        }
        if (clinicalSignals.hasWoundOrBurnWithoutPain) {
            signalPoints += 24
            alertFactors += pick(languageCode, "ferida ou queimadura sem sentir", "painless wound or burn")
        }
        if (clinicalSignals.changedColor) {
            signalPoints += 8
            alertFactors += pick(languageCode, "mudanca de cor", "skin color change")
        }

        when (clinicalSignals.durationBucket) {
            DurationBucket.MEDIUM -> {
                signalPoints += 8
                alertFactors += pick(languageCode, "persistencia acima de 3 meses", "persistence longer than 3 months")
            }
            DurationBucket.LONG -> {
                signalPoints += 15
                alertFactors += pick(languageCode, "persistencia acima de 12 meses", "persistence longer than 12 months")
            }
            DurationBucket.SHORT -> Unit
        }

        val noteFlags = extractNoteFlags(clinicalSignals.notes, languageCode)
        if (noteFlags.isNotEmpty()) {
            signalPoints += minOf(18, noteFlags.size * 6)
            alertFactors += noteFlags
        }

        val minimumScore = when {
            signalPoints >= 75 -> 78
            signalPoints >= 55 -> 62
            signalPoints >= 35 -> 48
            signalPoints >= 22 -> 35
            else -> 0
        }

        val visibleFindingsMinimumScore = estimateVisibleFindingsMinimumScore(response)
        val visualRiskFloorFromFindings = conservativeVisibleRiskFloor(visibleFindingsMinimumScore)
        val hasVisibleFindings = visibleFindingsMinimumScore > 0
        val hasParadoxicallyLowVisualScore =
            response.visualRiskScore in 1..14 &&
                visualRiskFloorFromFindings > response.visualRiskScore
        val shouldRescueVisualScore = hasVisibleFindings &&
            (
                response.visualRiskLevel == INSUFFICIENT_IMAGE_LEVEL ||
                    response.visualRiskScore <= 0 ||
                    hasParadoxicallyLowVisualScore
                )
        val visualRiskScore = if (shouldRescueVisualScore) {
            val visualFloor = if (
                response.visualRiskLevel == INSUFFICIENT_IMAGE_LEVEL ||
                    response.visualRiskScore <= 0
            ) {
                visibleFindingsMinimumScore
            } else {
                visualRiskFloorFromFindings
            }
            maxOf(response.visualRiskScore, visualFloor).coerceIn(0, 100)
        } else {
            response.visualRiskScore
        }
        val visualRiskLevel = if (
            shouldRescueVisualScore ||
            (hasVisibleFindings && response.visualRiskLevel == INSUFFICIENT_IMAGE_LEVEL)
        ) {
            scoreToRiskLevel(visualRiskScore)
        } else {
            response.visualRiskLevel
        }
        val shouldRaiseOverallScoreForVisual =
            hasParadoxicallyLowVisualScore &&
                visualRiskScore >= 45 &&
                response.score < visualRiskScore
        val guardedScore = when {
            response.riskLevel == INSUFFICIENT_IMAGE_LEVEL && hasVisibleFindings ->
                maxOf(response.score, visualRiskScore).coerceIn(0, 100)
            shouldRaiseOverallScoreForVisual ->
                maxOf(response.score, visualRiskScore).coerceIn(0, 100)
            else -> response.score
        }
        val guardedRiskLevel = if (
            (hasVisibleFindings && response.riskLevel == INSUFFICIENT_IMAGE_LEVEL) ||
            shouldRaiseOverallScoreForVisual
        ) {
            scoreToRiskLevel(guardedScore)
        } else {
            response.riskLevel
        }

        val distinctAlertFactors = alertFactors.distinct()
        val visibleRiskFactors = when {
            visibleFindingsMinimumScore >= 45 -> listOf(
                pick(languageCode, "achados visuais cutaneos descritos nas imagens", "visual skin findings described in the images"),
            )
            visibleFindingsMinimumScore >= 30 -> listOf(
                pick(languageCode, "alteracao visual cutanea descrita", "visible skin change described"),
            )
            else -> emptyList()
        }
        val clinicalScore = maxOf(response.clinicalNeuralRiskScore, minimumScore).coerceIn(0, 100)
        val clinicalLevel = if (clinicalScore > 0) {
            scoreToRiskLevel(clinicalScore)
        } else {
            response.clinicalNeuralRiskLevel
        }
        val modelLimitingFactors = response.riskFactors.filter(::isConfidenceLimitationFactor)
        val modelReassuringFactors = response.riskFactors.filter(::isReassuringFactor)
        val modelIncreasingFactors = response.riskFactors
            .filterNot(::isConfidenceLimitationFactor)
            .filterNot(::isReassuringFactor)
        val combinedRiskFactors = (modelIncreasingFactors + visibleRiskFactors + distinctAlertFactors).distinct()
        val combinedLimitingFactors = (response.confidenceLimitingFactors + modelLimitingFactors).distinct()
        val combinedReassuringFactors = (response.reassuringFactors + modelReassuringFactors).distinct()
        val combinedSymptoms = (response.relevantSymptoms + distinctAlertFactors).distinct()
        val baseReferralReason = response.referralReason.ifBlank {
            if (combinedRiskFactors.isNotEmpty()) {
                pick(
                    languageCode,
                    "Prioridade definida pela combinacao entre achados visuais e fatores clinicos: ${combinedRiskFactors.take(4).joinToString(", ")}.",
                    "Priority defined by the combination of visual findings and clinical factors: ${combinedRiskFactors.take(4).joinToString(", ")}.",
                )
            } else if (hasVisibleFindings) {
                pick(
                    languageCode,
                    "Prioridade definida pelos achados visuais descritos e sintomas informados.",
                    "Priority defined by the described visual findings and reported symptoms.",
                )
            } else {
                pick(
                    languageCode,
                    "Prioridade definida pelos achados visuais, sintomas informados e qualidade das imagens.",
                    "Priority defined by visual findings, reported symptoms, and image quality.",
                )
            }
        }
        val rawNextAction = response.nextAction.ifBlank {
            strengthenRecommendedAction("", maxOf(guardedScore, clinicalScore), languageCode)
        }
        val baseNextAction = normalizeVisibleFindingsNextAction(rawNextAction, hasVisibleFindings, languageCode)

        val baseResponse = response.copy(
            score = guardedScore,
            riskLevel = guardedRiskLevel,
            visualRiskScore = visualRiskScore,
            visualRiskLevel = visualRiskLevel,
            clinicalNeuralRiskScore = clinicalScore,
            clinicalNeuralRiskLevel = clinicalLevel,
            relevantSymptoms = combinedSymptoms,
            riskFactors = combinedRiskFactors,
            confidenceLimitingFactors = combinedLimitingFactors,
            reassuringFactors = combinedReassuringFactors,
            referralReason = baseReferralReason,
            nextAction = baseNextAction,
        )

        if (guardedScore >= minimumScore || minimumScore == 0) {
            return baseResponse
        }

        val adjustedScore = minimumScore.coerceIn(0, 100)
        val adjustedLevel = if (guardedRiskLevel == INSUFFICIENT_IMAGE_LEVEL && adjustedScore < 45 && !hasVisibleFindings) {
            INSUFFICIENT_IMAGE_LEVEL
        } else {
            scoreToRiskLevel(adjustedScore)
        }
        val consistencyNote = buildString {
            append(
                pick(
                    languageCode,
                    "Score elevado por consistencia clinica: a entrevista trouxe sinais que justificam maior prioridade",
                    "Score raised for clinical consistency: the interview included signs that justify higher priority",
                ),
            )
            if (distinctAlertFactors.isNotEmpty()) {
                append(" (")
                append(distinctAlertFactors.take(4).joinToString(", "))
                append(")")
            }
            append('.')
        }

        return baseResponse.copy(
            score = adjustedScore,
            riskLevel = adjustedLevel,
            nextAction = strengthenRecommendedAction(baseResponse.nextAction, adjustedScore, languageCode),
            consistencyNote = consistencyNote,
            scoreAdjusted = true,
        )
    }

    private fun estimateVisibleFindingsMinimumScore(response: ModelResponse): Int {
        val allFindings = (response.visualFindings + response.regionFindings.flatMap { it.findings })
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
            .filterNot(::isUnableToAssessFinding)

        if (allFindings.isEmpty()) {
            return 0
        }

        val normalizedFindings = allFindings.map(::normalizeText)
        val combinedText = normalizedFindings.joinToString(" ")
        val strongTerms = listOf(
            "lesao",
            "lesoes",
            "mancha",
            "placa",
            "hipocrom",
            "hipercrom",
            "hiperpigment",
            "eritem",
            "vermelh",
            "nodul",
            "infiltr",
            "ulcer",
            "ferida",
            "lesion",
            "patch",
            "plaque",
            "erythem",
            "redness",
            "hypopig",
            "hyperpig",
            "nodule",
            "ulcer",
            "wound",
        )
        val patternTerms = listOf(
            "borda",
            "delimit",
            "area definida",
            "diferenca de cor",
            "alteracao de cor",
            "textura",
            "descam",
            "ressec",
            "elevad",
            "difus",
            "distribuicao",
            "multipla",
            "perda de pelo",
            "queda de pelo",
            "border",
            "defined area",
            "color difference",
            "color change",
            "texture",
            "scal",
            "dry",
            "raised",
            "diffuse",
            "distribution",
            "multiple",
            "hair loss",
        )

        val strongHits = strongTerms.count(combinedText::contains)
        val patternHits = patternTerms.count(combinedText::contains)
        val findingCount = normalizedFindings.size

        return when {
            strongHits >= 4 || (strongHits >= 2 && patternHits >= 2) || (findingCount >= 3 && strongHits >= 2) -> 55
            strongHits >= 2 || patternHits >= 3 || (findingCount >= 2 && strongHits >= 1) -> 45
            strongHits >= 1 || patternHits >= 1 -> 30
            else -> 0
        }
    }

    private fun conservativeVisibleRiskFloor(visibleFindingsMinimumScore: Int): Int {
        return when {
            visibleFindingsMinimumScore >= 55 -> 45
            visibleFindingsMinimumScore >= 45 -> 35
            visibleFindingsMinimumScore >= 30 -> 25
            else -> 0
        }
    }

    private fun isUnableToAssessFinding(text: String): Boolean {
        val normalized = normalizeText(text)
        if (normalized.isBlank()) {
            return true
        }

        return containsAny(
            normalized,
            listOf(
                "nao foi possivel avaliar",
                "nao permite avaliar",
                "impossivel avaliar",
                "sem avaliacao visual",
                "sem achado visual",
                "nenhum achado visual",
                "nao ha achado visual",
                "sem lesao",
                "sem lesoes",
                "sem mancha",
                "ausencia de lesao",
                "ausencia de lesoes",
                "ausencia de mancha",
                "nao ha lesao",
                "nao ha lesoes",
                "nao foram observad",
                "nao se observa",
                "qualidade visual insuficiente",
                "imagem insuficiente",
                "not possible to assess",
                "cannot assess",
                "impossible to assess",
                "no visual assessment",
                "no visual finding",
                "no lesion",
                "no lesions",
                "no patch",
                "absence of lesion",
                "absence of lesions",
                "not observed",
                "visual quality insufficient",
                "insufficient image",
            ),
        )
    }

    private fun normalizeVisibleFindingsNextAction(
        action: String,
        hasVisibleFindings: Boolean,
        languageCode: String = "pt",
    ): String {
        val trimmed = action.trim()
        if (!hasVisibleFindings || trimmed.isBlank()) {
            return trimmed
        }

        val normalized = normalizeText(trimmed)
        val asksOnlyForRetake = containsAny(normalized, listOf("refazer", "repetir", "capturar novamente")) &&
            containsAny(normalized, listOf("foto", "imagem", "qualidade", "luz", "foco", "desfoque", "nitidez")) &&
            !containsAny(normalized, listOf("encaminh", "avaliacao presencial", "exame dermatoneurologico", "observar", "acompanhar"))

        if (!asksOnlyForRetake) {
            return trimmed
        }

        return pick(
            languageCode,
            "Usar os achados visiveis para orientar a triagem; se possivel, repetir a captura para melhorar a confianca, mas nao descartar a avaliacao atual.",
            "Use the visible findings to guide screening; if possible, repeat capture to improve confidence, but do not discard the current assessment.",
        )
    }

    private fun strengthenRecommendedAction(action: String, score: Int, languageCode: String = "pt"): String {
        val trimmed = action.trim()
        val normalized = normalizeText(trimmed)
        val hasReferralLanguage = listOf("encaminh", "avaliacao presencial", "avaliacao clinica", "servico").any {
            normalized.contains(it)
        } || listOf("refer", "in-person", "clinical evaluation", "service").any(normalized::contains)

        if (hasReferralLanguage) {
            return trimmed
        }

        val reinforcement = when {
            score >= 70 -> pick(
                languageCode,
                "Encaminhar para avaliacao clinica presencial prioritaria com exame dermatoneurologico.",
                "Refer for priority in-person clinical evaluation with dermatoneurologic examination.",
            )
            score >= 45 -> pick(
                languageCode,
                "Recomendar avaliacao clinica presencial para confirmar o quadro.",
                "Recommend in-person clinical evaluation to confirm the condition.",
            )
            trimmed.isEmpty() -> pick(
                languageCode,
                "Orientar observacao, registrar o caso e repetir as fotos se houver duvida, persistencia, dormencia ou progressao.",
                "Advise observation, record the case, and repeat photos if there is uncertainty, persistence, numbness, or progression.",
            )
            else -> return trimmed
        }

        if (trimmed.isEmpty()) {
            return reinforcement
        }

        return "$trimmed $reinforcement"
    }

    private fun extractNoteFlags(notes: String, languageCode: String = "pt"): List<String> {
        val normalized = normalizeText(notes)
        if (normalized.isBlank()) {
            return emptyList()
        }

        val flags = mutableListOf<String>()
        if (containsAny(normalized, listOf("formig", "choque", "fisgada", "parestes"))) {
            flags += pick(languageCode, "parestesia em observacoes livres", "paresthesia mentioned in free notes")
        }
        if (containsAny(normalized, listOf("fraquez", "segurar", "derruba", "levantar o pe", "pe caido"))) {
            flags += pick(languageCode, "fraqueza em observacoes livres", "weakness mentioned in free notes")
        }
        if (containsAny(normalized, listOf("crescendo", "aumentando", "espalhando", "piorando", "rapido"))) {
            flags += pick(languageCode, "progressao rapida em observacoes livres", "rapid progression mentioned in free notes")
        }
        if (containsAny(normalized, listOf("ressec", "seca", "sem pelo", "pelos cairam", "queda de pelos"))) {
            flags += pick(languageCode, "alteracao trofica em observacoes livres", "trophic skin change mentioned in free notes")
        }

        return flags.distinct()
    }

    private fun containsAny(text: String, terms: List<String>): Boolean {
        return terms.any(text::contains)
    }

    private fun pick(languageCode: String, portuguese: String, english: String): String {
        return if (languageCode == "en") english else portuguese
    }

    private fun isConfidenceLimitationFactor(text: String): Boolean {
        val normalized = normalizeText(text)
        return containsAny(
            normalized,
            listOf(
                "qualidade",
                "insuficient",
                "limitad",
                "desfoque",
                "pouca luz",
                "sombra",
                "baixo contraste",
                "nao foi possivel",
                "confianca visual",
                "quality",
                "limited",
                "blur",
                "low light",
                "shadow",
                "low contrast",
                "not possible",
                "visual confidence",
            ),
        )
    }

    private fun isReassuringFactor(text: String): Boolean {
        val normalized = normalizeText(text)
        return normalized.startsWith("ausencia ") ||
            normalized.startsWith("ausencia de") ||
            normalized.startsWith("sem ") ||
            normalized.contains("ausencia de") ||
            normalized.contains("nao ha sinais") ||
            normalized.contains("nao foram relatad") ||
            normalized.contains("curta duracao") ||
            normalized.contains("baixa especificidade") ||
            normalized.startsWith("absence ") ||
            normalized.startsWith("absence of") ||
            normalized.startsWith("no ") ||
            normalized.contains("absence of") ||
            normalized.contains("no signs") ||
            normalized.contains("not reported") ||
            normalized.contains("short duration") ||
            normalized.contains("low specificity")
    }

    private fun normalizeText(text: String): String {
        return Normalizer.normalize(text.lowercase(), Normalizer.Form.NFD)
            .replace("\\p{InCombiningDiacriticalMarks}+".toRegex(), "")
    }

    private fun extractJsonBlock(responseText: String): String {
        val trimmed = responseText.trim()
        if (trimmed.startsWith("```")) {
            val lines = trimmed.lines()
            if (lines.size >= 3) {
                return lines.subList(1, lines.lastIndex).joinToString("\n").trim()
            }
        }

        val start = trimmed.indexOf('{')
        val end = trimmed.lastIndexOf('}')
        if (start >= 0 && end > start) {
            return trimmed.substring(start, end + 1)
        }

        return trimmed
    }

    private fun scoreToRiskLevel(score: Int): String {
        return when {
            score >= 70 -> "high"
            score >= 45 -> "moderate"
            else -> "low"
        }
    }

    private fun normalizeRiskLevel(value: String): String {
        return when (normalizeText(value)) {
            "high", "alto", "alta" -> "high"
            "moderate", "medium", "moderado", "moderada" -> "moderate"
            "insufficient", "insufficient_image", "image_insufficient", "imagem insuficiente", "imagem_insuficiente" -> INSUFFICIENT_IMAGE_LEVEL
            else -> "low"
        }
    }

    private fun backendFromWire(value: String): Backend {
        return when (value.lowercase()) {
            "cpu" -> Backend.CPU()
            else -> Backend.GPU()
        }
    }

    private fun respondSuccess(result: MethodChannel.Result, value: Any?) {
        runOnUiThread {
            result.success(value)
        }
    }

    private fun respondError(result: MethodChannel.Result, code: String, message: String) {
        runOnUiThread {
            result.error(code, message, null)
        }
    }

    private data class InitializationOutcome(
        val modelPath: String,
        val backend: String,
        val message: String,
    )

    private class ModelJsonException(
        message: String,
        val rawResponse: String,
    ) : IllegalStateException(message)

    // Normalized questionnaire signals captured in Flutter and reused during
    // prompt assembly plus post-processing.
    private data class ClinicalSignals(
        val hasNumbness: Boolean,
        val changedColor: Boolean,
        val hasContactWithConfirmedCase: Boolean,
        val hasNervePainOrShock: Boolean,
        val hasMuscleWeakness: Boolean,
        val hasDrynessOrHairLoss: Boolean,
        val hasMultipleLesions: Boolean,
        val hasWoundOrBurnWithoutPain: Boolean,
        val durationLabel: String,
        val notes: String,
    ) {
        val durationBucket: DurationBucket
            get() = DurationBucket.fromLabel(durationLabel)
    }

    // Region-scoped visual summary returned to Dart.
    private data class RegionFinding(
        val region: String,
        val imageQuality: String,
        val findings: List<String>,
    ) {
        fun toWireMap(): Map<String, Any> {
            return mapOf(
                "region" to region,
                "imageQuality" to imageQuality,
                "findings" to findings,
            )
        }
    }

    // Wire contract consumed by TriageResult.fromMap() on the Flutter side.
    private data class ModelResponse(
        val score: Int,
        val riskLevel: String,
        val imageQualitySummary: List<String>,
        val regionFindings: List<RegionFinding>,
        val visualFindings: List<String>,
        val visualRiskScore: Int,
        val visualRiskLevel: String,
        val clinicalNeuralRiskScore: Int,
        val clinicalNeuralRiskLevel: String,
        val relevantSymptoms: List<String>,
        val riskFactors: List<String>,
        val confidenceLimitingFactors: List<String>,
        val reassuringFactors: List<String>,
        val reasoning: List<String>,
        val referralReason: String,
        val nextAction: String,
        val consistencyNote: String? = null,
        val scoreAdjusted: Boolean = false,
    ) {
        fun toWireMap(): Map<String, Any> {
            val payload = mutableMapOf<String, Any>(
                "score" to score,
                "riskLevel" to riskLevel,
                "imageQualitySummary" to imageQualitySummary,
                "regionFindings" to regionFindings.map { it.toWireMap() },
                "visualFindings" to visualFindings,
                "visualRiskScore" to visualRiskScore,
                "visualRiskLevel" to visualRiskLevel,
                "clinicalNeuralRiskScore" to clinicalNeuralRiskScore,
                "clinicalNeuralRiskLevel" to clinicalNeuralRiskLevel,
                "relevantSymptoms" to relevantSymptoms,
                "riskFactors" to riskFactors,
                "riskIncreasingFactors" to riskFactors,
                "confidenceLimitingFactors" to confidenceLimitingFactors,
                "reassuringFactors" to reassuringFactors,
                "reasoning" to reasoning,
                "referralReason" to referralReason,
                "nextAction" to nextAction,
                "recommendedAction" to nextAction,
                "scoreAdjusted" to scoreAdjusted,
            )
            consistencyNote?.takeIf { it.isNotBlank() }?.let {
                payload["consistencyNote"] = it
            }
            return payload
        }
    }

    private enum class DurationBucket {
        SHORT,
        MEDIUM,
        LONG;

        companion object {
            fun fromLabel(label: String): DurationBucket {
                val normalized = Normalizer.normalize(label.lowercase(), Normalizer.Form.NFD)
                    .replace("\\p{InCombiningDiacriticalMarks}+".toRegex(), "")

                return when {
                    normalized.contains("mais de 12") || normalized.contains("> 12") -> LONG
                    normalized.contains("3 a 12") || normalized.contains("3-12") -> MEDIUM
                    else -> SHORT
                }
            }
        }
    }

    private fun JSONArray?.toStringList(): List<String> {
        if (this == null) {
            return emptyList()
        }

        val items = mutableListOf<String>()
        for (index in 0 until length()) {
            val item = cleanModelText(optString(index))
            if (item.isNotEmpty()) {
                items += item
            }
        }
        return items
    }

    private fun JSONArray?.toRegionFindings(): List<RegionFinding> {
        if (this == null) {
            return emptyList()
        }

        val items = mutableListOf<RegionFinding>()
        for (index in 0 until length()) {
            val item = optJSONObject(index) ?: continue
            val findings = item.optJSONArray("findings").toStringList()
            val region = item.optString("region", "Regiao ${index + 1}").trim()
            val imageQuality = item.optString("image_quality", item.optString("imageQuality", "")).trim()
            if (region.isNotEmpty() || imageQuality.isNotEmpty() || findings.isNotEmpty()) {
                items += RegionFinding(
                    region = region.ifBlank { "Regiao ${index + 1}" },
                    imageQuality = imageQuality,
                    findings = findings,
                )
            }
        }
        return items
    }

        companion object {
                private const val CHANNEL_NAME = "com.example.hansen_guard/litert_lm"
                private const val DEFAULT_MODEL_FILENAME = "gemma-4-E2B-it.litertlm"
                private const val MAX_ANALYSIS_IMAGES = 6
                private const val INSUFFICIENT_IMAGE_LEVEL = "insufficient_image"
                private const val MAX_REPAIR_RESPONSE_CHARS = 2200

                private val SYSTEM_PROMPT =
                        """
                        Voce apoia triagem comunitaria de hanseniase. Nao diagnostique e nao substitua avaliacao clinica.
                        Responda sempre em JSON valido e compacto, sem markdown.
                        Compare as imagens como um mesmo caso, agrupando por regiao.
                        Diferencie risco visual dermatologico de risco clinico-neural.
                        Use "insufficient_image" somente quando nao houver pele/lesao avaliavel.
                        Baixa resolucao ou desfoque reduzem confianca, mas nao zeram o risco se houver achado visivel.
                        Calibracao: dormencia/contato/duracao longa elevam risco clinico; mancha/placa persistente com diferenca de cor eleva risco visual; foto escura sem pele avaliavel gera insufficient_image.
                        """.trimIndent()
        }
}
