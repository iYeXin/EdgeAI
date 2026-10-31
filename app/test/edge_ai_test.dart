import 'package:edge_ai/engine/edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('engine config maps memory and context policy', () {
    const config = EngineConfig(
      modelPath: '/models/test.gguf',
      backend: ComputeBackend.cpu,
      contextSize: 0,
      memoryBudgetBytes: 4 * 1024 * 1024 * 1024,
      minContext: 512,
      maxContext: 4096,
    );
    final map = config.toMap();
    expect(map['backend'], 2);
    expect(map['contextSize'], 0);
    expect(map['memoryBudgetBytes'], 4 * 1024 * 1024 * 1024);
    expect(map['minContext'], 512);
    expect(map['maxContext'], 4096);
  });

  test('generation params expose sampling and stop controls', () {
    const params = GenerationParams(
      maxTokens: 64,
      temperature: 0.2,
      topP: 0.9,
      topK: 20,
      minP: 0.01,
      repeatPenalty: 1.05,
      seed: 42,
      stopSequences: ['</answer>', '\n\nUser:'],
    );
    final map = params.toMap();
    expect(map['maxTokens'], 64);
    expect(map['seed'], 42);
    expect(map['stopSequences'], ['</answer>', '\n\nUser:']);
  });

  test('context plan reports usage and trimming', () {
    const plan = ContextPlan(
      promptTokens: 512,
      maxOutputTokens: 256,
      nCtx: 2048,
      droppedMessages: 3,
      totalMessages: 9,
      fits: true,
      promptBytes: 2048,
    );
    expect(plan.usage, closeTo(0.25, 0.0001));
    expect(plan.droppedMessages, 3);
  });
}
