using System;

namespace Tallow;

/// Marks a public static method as a node for the visual scripting graph editor.
/// Parameters become inputs and the return value becomes the output. Supported types are
/// float, int32, bool, Vector3 and String. An optional first Component parameter
/// receives the graph component itself and does not create a pin. A void method is an action node with flow pins.
///
///   static class MyNodes
///   {
///       [GraphNode] public static float Pulse(float time, float speed) => Math.Sin(time * speed) * 0.5f + 0.5f;
///   }
[AttributeUsage(.Method, .ReflectAttribute | .AlwaysIncludeTarget, ReflectUser = .All)]
struct GraphNodeAttribute : Attribute
{
}

/// Put on a class that contains [GraphNode] methods so its methods stay visible to the editor.
[AttributeUsage(.Class, .ReflectAttribute | .AlwaysIncludeTarget, ReflectUser = .All, AlwaysIncludeUser = .IncludeAllMethods | .AssumeInstantiated)]
struct GraphLibraryAttribute : Attribute
{
}

/// A few ready-made code nodes; they also show how to write your own.
[GraphLibrary]
static class GraphNodes
{
	[GraphNode] public static float Wave(float time, float speed, float amplitude) => Math.Sin(time * speed) * amplitude;
	[GraphNode] public static float Distance(Vector3 a, Vector3 b) => (a - b).Length;
	[GraphNode] public static Vector3 Scale(Vector3 value, float factor) => value * factor;
	[GraphNode] public static float Clamp(float value, float min, float max) => Mathf.Clamp(value, min, max);
	[GraphNode] public static void Print(String text) => Log.Info(text);
	[GraphNode] public static void PrintNumber(float value) => Log.Info(scope $"{value}");
}
