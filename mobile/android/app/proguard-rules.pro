# Gson stores generic type information in the class file via signatures.
# R8 strips these by default, which breaks TypeToken-based (de)serialization
# used by flutter_local_notifications to persist scheduled notifications.
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses
-keepattributes EnclosingMethod

-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken
-keep class com.google.gson.** { *; }

-keep class com.dexterous.flutterlocalnotifications.** { *; }
