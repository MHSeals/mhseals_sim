#if UNITY_EDITOR
using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

/// <summary>The MHSeals menu: one-click actions for RoboBoat developers. Thin wrappers over the
/// existing build and scene code, so the command-line paths (-executeMethod ...) stay the same.</summary>
public static class MHSealsMenu {
    private const string CourseScene = "Assets/Scenes/Roboboat Course.unity";

    [MenuItem("MHSeals/Open RoboBoat Course", priority = 0)]
    private static void OpenCourse() {
        if (EditorSceneManager.SaveCurrentModifiedScenesIfUserWantsTo())
            EditorSceneManager.OpenScene(CourseScene);
    }

    [MenuItem("MHSeals/Build/Linux Player", priority = 20)]
    private static void BuildLinux() => Build(false);

    [MenuItem("MHSeals/Build/Windows Player", priority = 21)]
    private static void BuildWindows() => Build(true);

    [MenuItem("MHSeals/Build/Show Builds Folder", priority = 40)]
    private static void ShowBuilds() {
        Directory.CreateDirectory("Builds");
        EditorUtility.RevealInFinder(Path.GetFullPath("Builds"));
    }

    [MenuItem("MHSeals/Help/README", priority = 100)]
    private static void Readme() => Application.OpenURL("https://github.com/MHSeals/mhseals_sim#readme");

    [MenuItem("MHSeals/Help/Report an Issue", priority = 101)]
    private static void Issue() => Application.OpenURL("https://github.com/MHSeals/mhseals_sim/issues");

    private static void Build(bool windows) {
        if (!EditorSceneManager.SaveCurrentModifiedScenesIfUserWantsTo()) return;
        string output = CranePerformanceBuild.DefaultOutput(windows);
        try {
            CranePerformanceBuild.BuildPlayer(null, windows, output);
            EditorUtility.RevealInFinder(Path.GetFullPath(output));
        } catch (System.Exception e) {
            EditorUtility.DisplayDialog("mhseals_sim build failed", e.Message +
                (windows ? "\n\nWindows builds from Linux need the 'Windows Build Support (Mono)' module in Unity Hub."
                         : "\n\nLinux builds from Windows need the 'Linux Build Support (Mono)' module in Unity Hub."), "OK");
            throw;
        }
    }
}
#endif
