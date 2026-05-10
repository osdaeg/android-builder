FROM debian:12

ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools

# Dependencias del sistema
RUN apt-get update && apt-get install -y \
    wget unzip git curl openjdk-17-jdk \
    lib32stdc++6 lib32z1 libc6-i386 \
    nodejs \
    && rm -rf /var/lib/apt/lists/*

# Gradle standalone (para generar wrappers si hace falta)
ENV GRADLE_VERSION=8.7
RUN wget -q https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip \
 && unzip -q gradle-${GRADLE_VERSION}-bin.zip -d /opt \
 && ln -s /opt/gradle-${GRADLE_VERSION}/bin/gradle /usr/bin/gradle \
 && rm gradle-${GRADLE_VERSION}-bin.zip

# Android SDK — cmdline-tools
RUN mkdir -p $ANDROID_HOME/cmdline-tools
WORKDIR $ANDROID_HOME/cmdline-tools

RUN wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
 && unzip -q commandlinetools-linux-*.zip \
 && mv cmdline-tools latest \
 && rm commandlinetools-linux-*.zip

# Aceptar licencias y descargar componentes
RUN yes | sdkmanager --licenses > /dev/null 2>&1

RUN sdkmanager \
    "platform-tools" \
    "platforms;android-35" \
    "build-tools;35.0.0"

# Calentar caché de Gradle (descarga Gradle wrapper 8.7 en la imagen)
# Así el primer build no pierde tiempo bajándolo
RUN mkdir -p /tmp/warmup && cd /tmp/warmup \
 && gradle init --type basic --dsl kotlin --no-incubating -q 2>/dev/null || true \
 && gradle wrapper --gradle-version $GRADLE_VERSION -q 2>/dev/null || true \
 && rm -rf /tmp/warmup

WORKDIR /workspace

# local.properties se genera en cada job via workflow (ver build.yml.template)
# No se hardcodea aquí para que sea compatible con builds locales también
