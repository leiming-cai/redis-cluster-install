import org.springframework.data.redis.connection.RedisClusterConfiguration;
import org.springframework.data.redis.connection.RedisConnection;
import org.springframework.data.redis.connection.jedis.JedisClientConfiguration;
import org.springframework.data.redis.connection.jedis.JedisConnectionFactory;
import org.springframework.data.redis.core.RedisCallback;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.data.redis.core.SessionCallback;
import org.springframework.data.redis.serializer.GenericJackson2JsonRedisSerializer;
import org.springframework.data.redis.serializer.RedisSerializer;
import org.springframework.data.redis.serializer.StringRedisSerializer;

import java.util.Arrays;
import java.util.Collections;

/**
 * 探针：SDR 2.7.18 + jedis 3.10.0，在【真 Redis 集群】下对比
 * executePipelined(...) 与 execute(...) 的行为。
 *
 * 这是 napstarweb 集群分支改造的【地基】：
 *   - executePipelined 在集群下必抛 UnsupportedOperationException（回调体一次都不跑）
 *   - execute 在集群下正常，且每条单 key 命令按 slot 正确路由
 *
 * 装配方式与生产 RedisUtilConfig.RedisClusterConfig 一致。
 */
// The file is named cluster-execute-probe.java, not ClusterExecuteProbe.java,
// and javac refuses a PUBLIC class whose filename does not match it. The class
// is therefore package-private: this file is a standalone script, never
// imported by anything, so public visibility buys nothing.
class ClusterExecuteProbe {

    public static void main(String[] args) {
        try {
            run(args);
        } catch (Throwable t) {
            System.out.println("FATAL: " + t);
            t.printStackTrace(System.out);
            System.exit(2);
        }
        System.out.flush();
        // commons-pool2 的 evictor 是【非守护】线程：没有这句，JVM 永远不会退出，
        // 探针的退出码也就永远不会回到脚本里。
        System.exit(0);
    }

    static void run(String[] args) {
        String nodes = args.length > 0 ? args[0] : "127.0.0.1:16379";
        String password = args.length > 1 ? args[1] : "CpsE2eClusterPw";

        RedisClusterConfiguration clusterConfig =
                new RedisClusterConfiguration(Arrays.asList(nodes.split(",")));
        if (!password.isEmpty()) {
            clusterConfig.setPassword(password);
        }
        clusterConfig.setMaxRedirects(3);

        JedisClientConfiguration clientConfig = JedisClientConfiguration.builder()
                .usePooling()
                .poolConfig(new org.apache.commons.pool2.impl.GenericObjectPoolConfig())
                .and()
                .build();

        JedisConnectionFactory factory = new JedisConnectionFactory(clusterConfig, clientConfig);
        factory.afterPropertiesSet();

        RedisTemplate<String, Object> template = new RedisTemplate<>();
        template.setConnectionFactory(factory);
        template.setKeySerializer(new StringRedisSerializer());
        template.setHashKeySerializer(new StringRedisSerializer());
        template.setHashValueSerializer(new GenericJackson2JsonRedisSerializer());
        template.setValueSerializer(new GenericJackson2JsonRedisSerializer());
        template.afterPropertiesSet();

        int failures = 0;

        RedisConnection conn = factory.getConnection();
        System.out.println("connection class = " + conn.getClass().getName());
        if (!"org.springframework.data.redis.connection.jedis.JedisClusterConnection".equals(
                conn.getClass().getName())) {
            System.out.println("FAIL: expected JedisClusterConnection");
            failures++;
        }
        System.out.println("PING = " + conn.ping());
        conn.close();

        // 1. 对照组：非 pipeline 的 opsForHash().putAll()
        try {
            template.opsForHash().putAll("probe:ctl", Collections.singletonMap("f1", "v1"));
            System.out.println("OK   opsForHash().putAll -> " + template.opsForHash().entries("probe:ctl"));
            template.delete("probe:ctl");
        } catch (Throwable e) {
            System.out.println("FAIL opsForHash().putAll -> " + e);
            failures++;
        }

        // 2. executePipelined 在集群下必须抛（这是改造的前提）
        try {
            template.executePipelined(new RedisCallback<Object>() {
                @Override
                public Object doInRedis(RedisConnection c) {
                    c.hSet("probe:single".getBytes(), "f".getBytes(), "v".getBytes());
                    System.out.println("  >>> 回调体执行了（说明命令发出去了）");
                    return null;
                }
            });
            System.out.println("FAIL executePipelined did NOT throw (cluster mode?)");
            failures++;
        } catch (UnsupportedOperationException e) {
            System.out.println("OK   executePipelined threw UnsupportedOperationException: " + e.getMessage());
            // The callback must NOT have run. If it had, the ">>> 回调体执行了"
            // line above would be in the output -- and, worse, a Redis command
            // would have been sent, which is exactly what the cluster branch
            // relies on NOT happening.
            System.out.println("OK   executePipelined 回调体没有执行（命令一条都没发出去）");
            // Belt and braces: the key the callback WOULD have written must not
            // exist. The callback's own print proves the callback body did not
            // run; this proves the command did not reach Redis either. Without
            // this the probe would still pass if some future SDR version ran
            // the callback and then failed to send.
            if (template.opsForHash().hasKey("probe:single", "f")) {
                System.out.println("FAIL executePipelined 竟然把 probe:single 写进去了");
                failures++;
            } else {
                System.out.println("OK   executePipelined 没有写入 probe:single");
            }
            // The probe must not leave keys behind in the cluster it is
            // measuring: a leftover probe:single would make the NEXT run's
            // hasKey() check fail for a reason that has nothing to do with
            // pipelines.
            template.delete("probe:single");
        } catch (Throwable e) {
            System.out.println("FAIL executePipelined threw the wrong type: " + e);
            failures++;
        }

        // 3. execute 在集群下必须能写能读
        try {
            // The raw bytes written by the callback MUST be encoded the way the
            // template's hash-value serializer would encode them, or the read
            // back below deserialises something the writer never wrote.
            // GenericJackson2JsonRedisSerializer encodes the String "v" as the
            // JSON text `"v"` (quotes included); writing the bare bytes `v`
            // makes the read-back fail with a JSON parse error, which says
            // nothing about the cluster and everything about the probe.
            //
            // The serializer is used through a raw RedisSerializer<Object>: the
            // template's own accessor is RedisSerializer<?>, and calling
            // serialize("v") on that wildcard does not compile.
            @SuppressWarnings("unchecked")
            RedisSerializer<Object> valueSerializer =
                    (RedisSerializer<Object>) template.getHashValueSerializer();
            final byte[] valueBytes = valueSerializer.serialize("v");
            template.execute(new RedisCallback<Object>() {
                @Override
                public Object doInRedis(RedisConnection c) {
                    c.hSet("probe:exec".getBytes(), "f".getBytes(), valueBytes);
                    System.out.println("  >>> 回调体执行了（说明命令发出去了）");
                    return null;
                }
            });
            Object read = template.opsForHash().get("probe:exec", "f");
            System.out.println("OK   execute wrote, read back = " + read);
            if (!"v".equals(String.valueOf(read))) {
                System.out.println("FAIL execute write did not land (read back = " + read + ")");
                failures++;
            }
            template.delete("probe:exec");
        } catch (Throwable e) {
            System.out.println("FAIL execute -> " + e);
            failures++;
        }

        // 4. SessionCallback 重载同样抛
        try {
            template.executePipelined(new SessionCallback<Object>() {
                @Override
                @SuppressWarnings("unchecked")
                public <K, V> Object execute(
                        org.springframework.data.redis.core.RedisOperations<K, V> operations) {
                    return null;
                }
            });
            System.out.println("FAIL executePipelined(SessionCallback) did NOT throw");
            failures++;
        } catch (UnsupportedOperationException e) {
            System.out.println("OK   executePipelined(SessionCallback) threw UnsupportedOperationException");
        } catch (Throwable e) {
            System.out.println("FAIL executePipelined(SessionCallback) threw the wrong type: " + e);
            failures++;
        }

        factory.destroy();
        System.out.println(failures == 0 ? "PROBE PASSED" : "PROBE FAILED (" + failures + ")");
        if (failures != 0) {
            throw new IllegalStateException("probe failures: " + failures);
        }
    }
}
