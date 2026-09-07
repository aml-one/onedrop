# MediaPipe Tasks Vision (Hand Landmarker) — JNI + protobuf + Flogger.
# Graph.<clinit> calls FluentLogger.forEnclosingClass(); R8 renaming that
# class crashes with "no caller found on the stack".
-keep class com.google.mediapipe.** { *; }
-keep class com.google.protobuf.** { *; }
-keep class com.google.common.flogger.** { *; }
-keep class com.google.common.** { *; }
-keep class * extends com.google.common.flogger.backend.Platform$LogCallerFinder { *; }
-dontwarn com.google.mediapipe.**
-dontwarn com.google.protobuf.**
-dontwarn com.google.common.flogger.**

# Annotation-processor stubs pulled by MediaPipe AutoValue (not in the APK).
-dontwarn javax.lang.model.SourceVersion
-dontwarn javax.lang.model.element.Element
-dontwarn javax.lang.model.element.ElementKind
-dontwarn javax.lang.model.type.TypeMirror
-dontwarn javax.lang.model.type.TypeVisitor
-dontwarn javax.lang.model.util.SimpleTypeVisitor8

# GalleryEngine.nativeAlive reads FlutterJNI.isAttached via the engine field.
-keepclassmembers class io.flutter.embedding.engine.FlutterEngine {
    io.flutter.embedding.engine.FlutterJNI flutterJNI;
}
-keepclassmembers class io.flutter.embedding.engine.FlutterJNI {
    public boolean isAttached();
}
