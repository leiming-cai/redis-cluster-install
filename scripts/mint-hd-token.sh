#!/bin/bash
# 用应用自己的 JWTUtil 铸一个 token，写到 /tmp/hd-token.txt。
#
# 为什么需要：华盾 napstarweb 的 shiroconfig 对 /** 要求 jwt，
# 而登录接口要的是 SM2/SM4 加密过的密码（安装包 seed 里的 hash 解不开）。
# 直接用**应用认可**的 JWTUtil 造 token，比猜密码可靠。
#
# 依据（实测自源码）:
#   JWTUtil.getToken(userId, userName, timeout) -> HMAC512(Constants.TOKEN_KEY)
#   Constants.TOKEN_KEY = "SAC"     (platform/backend/common/util/.../constant/Constants.java)
#   JWTFilter 从请求头 "Authorization" 取 token
#   ShiroRealm.doGetAuthenticationInfo: JWTUtil.getUserId(token) -> 查 base_user -> JWTUtil.verify(token, userid)
set -uo pipefail
APP=/opt/napstar_app
OUT=/tmp/hd-token.txt
JAR="${JAR:-web-controller-3.0.0.jar}"

cd /tmp && rm -rf mint && mkdir mint && cd mint
unzip -o -q "$APP/$JAR" 'BOOT-INF/lib/*' -d . 2>/dev/null
CP=$(find BOOT-INF/lib -name '*.jar' | tr '\n' ':')

UID_ARG=$(PGPASSWORD=postgres psql -h 127.0.0.1 -U postgres -d napstar -Atc \
  "select id::text from info.base_user where login_name='super'" 2>/dev/null | head -1)
if [ -z "$UID_ARG" ]; then
  echo "ERROR: 找不到 super 用户"; exit 1
fi
echo "super userId = $UID_ARG"

cat > Mint.java <<'EOF'
import com.sac.platform.modelsever.authentication.jwt.JWTUtil;
public class Mint {
  public static void main(String[] a) throws Exception {
    System.out.println(JWTUtil.getToken(a[0], a.length > 1 ? a[1] : "super", 1));
  }
}
EOF

JAVAC=/opt/software/jdk-21.0.2/bin/javac
JAVA=/opt/software/jdk-21.0.2/bin/java
"$JAVAC" -proc:none -nowarn -cp "$CP" -d . Mint.java 2>/dev/null || {
  echo "ERROR: javac 失败"; exit 1; }
TOK=$("$JAVA" -cp "$CP:." Mint "$UID_ARG" super 2>/dev/null)
if [ -z "$TOK" ]; then echo "ERROR: 没拿到 token"; exit 1; fi
echo "$TOK" > "$OUT"
echo "token 已写入 $OUT (${#TOK} chars)"
