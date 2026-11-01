# 华盾 napstar2.0 环境镜像
#
# 从门户镜像派生（复用 JDK8/JDK21/PG14/Redis/ZK/Kafka/Nacos 的安装），
# 但**只覆盖配置**，不改二进制。
#
# ⚠️ 命名契约：本镜像属于华盾 napstar2.0 那套，名字带 hd- 前缀。
#    门户那套是 cpsweb-env:1.0，两者完全独立。
FROM cpsweb-env:1.0

LABEL org.opencontainers.image.title="hd-napstar-env"
LABEL org.opencontainers.image.description="Huading napstar2.0 environment (isolated from the portal cpsweb stack)"

# ---- 中间件配置（由 prepare-configs.sh 从安装包生成）----
COPY generated/redis/redis.conf       /opt/software/redis-8.10.0/config/redis.conf
COPY generated/redis/redismaster.conf /opt/software/redis-8.10.0/config/redismaster.conf
COPY generated/zookeeper/zoo.cfg      /opt/software/apache-zookeeper-3.9.0-bin/conf/zoo.cfg
COPY generated/kafka/server.properties.node1 /opt/software/kafka_2.13-2.8.0/config/server.properties

# Nacos 端口 18848 —— 安装包 install_nacos.sh:95 做的正是这个改写
RUN sed -i 's/^server\.port=8848/server.port=18848/' /opt/software/nacos/conf/application.properties

# PG 软链：安装包的 init_postgres_info.sh 硬编码 PG_BIN=/usr/local/pgsql14/bin
RUN ln -sfn /usr/lib/postgresql/14/bin /usr/local/pgsql14

# 数据目录
RUN mkdir -p /opt/software/redis-8.10.0/logs/6379 /opt/software/redis-8.10.0/logs/6389 \
             /opt/software/kafka_2.13-2.8.0/data \
             /opt/napstar_app /opt/hd/logs /opt/software/hd-mwdata

COPY entrypoint.sh       /usr/local/bin/hd-entrypoint.sh
COPY entrypoint-node2.sh /usr/local/bin/hd-entrypoint-node2.sh
RUN chmod +x /usr/local/bin/hd-entrypoint.sh /usr/local/bin/hd-entrypoint-node2.sh

ENV JAVA_HOME=/opt/software/jdk8u292-b10
ENV JAVA_APP_HOME=/opt/software/jdk-21.0.2
ENV NACOS_HOME=/opt/software/nacos
ENV ZOOKEEPER_HOME=/opt/software/apache-zookeeper-3.9.0-bin
ENV KAFKA_HOME=/opt/software/kafka_2.13-2.8.0
ENV REDIS_HOME=/opt/software/redis-8.10.0
ENV PATH=${JAVA_HOME}/bin:${NACOS_HOME}/bin:${ZOOKEEPER_HOME}/bin:${KAFKA_HOME}/bin:${REDIS_HOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 内存约束 —— 本机只有 3.9GB 内存，门户容器已占 ~380MB
# ⚠️ 不设上限的话，这个容器会吃光宿主机内存并触发**宿主机的** OOM killer ——
#    那会连带杀掉门户容器里的 Nacos（实测踩过：门户 cpsweb 的 OOMKilled=true，
#    它的 Nacos 就是在 11 小时前被宿主 OOM 杀掉的）。
ENV NACOS_JVM_OPTS="-Xms256m -Xmx512m -Xmn128m"
ENV KAFKA_HEAP_OPTS="-Xms64M -Xmx192M"
ENV ZK_HEAP_SIZE="192M"

VOLUME /opt/napstar_app
WORKDIR /opt/napstar_app
ENTRYPOINT ["/usr/local/bin/hd-entrypoint.sh"]
