namespace CSharpGameplay;

// This reference verifies that the main game assembly can see defined assemblies.
public static class GameRoot
{
    public static Type GameplayComponent => typeof(Gameplay.MoveRight);
}
