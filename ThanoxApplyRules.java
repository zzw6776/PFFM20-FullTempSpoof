public class ThanoxApplyRules {
    private static final String RULE_NAME = "Google Play 自动切换 GMS 状态";
    private static final String WHITE_LIST_VAR = "gmsWhiteList";
    private static final String OLD_RULE_1 = "打开 Google Play 时解挂谷歌服务";
    private static final String OLD_RULE_2 = "退出 Google Play 或锁屏时挂起谷歌服务";

    private static final String RULE_JSON = "{"
            + "\"name\":\"" + RULE_NAME + "\","
            + "\"description\":\"进入白名单应用时恢复 GMS/GSF，离开白名单应用时挂起并停止 GMS/GSF\","
            + "\"priority\":1,"
            + "\"condition\":\"frontPkgChanged\","
            + "\"actions\":["
            + "\"if (frontPkgChanged && globalVarOf$" + WHITE_LIST_VAR + ".contains(to)) { su.exe('pm unsuspend --user 0 com.google.android.gms com.google.android.gsf'); } else if (frontPkgChanged && globalVarOf$" + WHITE_LIST_VAR + ".contains(from) && !globalVarOf$" + WHITE_LIST_VAR + ".contains(to)) { su.exe('pm suspend --user 0 com.google.android.gms com.google.android.gsf'); su.exe('am force-stop com.google.android.gms'); su.exe('am force-stop com.google.android.gsf'); su.exe('killall com.google.android.gms com.google.android.gms.persistent com.google.android.gms.unstable com.google.android.gsf'); }\""
            + "]"
            + "}";

    public static void main(String[] args) throws Exception {
        Class<?> nativeClass = Class.forName("github.tornaco.android.thanos.core.app.ThanosManagerNative");
        Object thanos = nativeClass.getMethod("getDefault").invoke(null);
        if (thanos == null) {
            throw new IllegalStateException("Thanox service not found");
        }
        System.out.println("Thanox: " + call(thanos, "whoAreYou") + " " + call(thanos, "getVersionName"));

        Object profile = call(thanos, "getProfileManager");
        call(profile, "setLogEnabled", new Class<?>[]{boolean.class}, true);
        call(profile, "setShellSuSupportInstalled", new Class<?>[]{boolean.class}, true);
        System.out.println("SU API enabled: " + call(profile, "isShellSuSupportInstalled"));
        ensureWhiteList(profile);

        Class<?> callbackClass = Class.forName("github.tornaco.android.thanos.core.profile.IRuleAddCallback");
        Object existing = call(profile, "getRuleByName", new Class<?>[]{String.class}, RULE_NAME);
        if (existing != null) {
            int id = (Integer) call(existing, "getId");
            call(profile, "updateRule", new Class<?>[]{int.class, String.class, callbackClass, int.class}, id, RULE_JSON, null, 1);
            call(profile, "enableRule", new Class<?>[]{int.class}, id);
            System.out.println("Updated rule id=" + id);
        } else {
            call(profile, "addRule", new Class<?>[]{String.class, int.class, String.class, callbackClass, int.class}, "Codex", 1, RULE_JSON, null, 1);
            Object added = call(profile, "getRuleByName", new Class<?>[]{String.class}, RULE_NAME);
            if (added != null) {
                int id = (Integer) call(added, "getId");
                call(profile, "enableRule", new Class<?>[]{int.class}, id);
                System.out.println("Added rule id=" + id);
            }
        }

        deleteByName(profile, OLD_RULE_1);
        deleteByName(profile, OLD_RULE_2);

        Object rule = call(profile, "getRuleByName", new Class<?>[]{String.class}, RULE_NAME);
        if (rule == null) {
            System.out.println("Final rule: missing");
        } else {
            System.out.println("Final rule: " + call(rule, "getId") + " enabled=" + call(rule, "getEnabled"));
        }

        call(profile, "setProfileEnabled", new Class<?>[]{boolean.class}, false);
        Thread.sleep(1000);
        call(profile, "setProfileEnabled", new Class<?>[]{boolean.class}, true);
        System.out.println("Profile reloaded");
    }

    private static void ensureWhiteList(Object profile) throws Exception {
        boolean exists = (Boolean) call(profile, "isGlobalRuleVarByNameExists", new Class<?>[]{String.class}, WHITE_LIST_VAR);
        if (!exists) {
            boolean added = (Boolean) call(profile, "addGlobalRuleVar", new Class<?>[]{String.class, String[].class},
                    WHITE_LIST_VAR, new String[]{"com.android.vending"});
            System.out.println("Created global var " + WHITE_LIST_VAR + "=" + added);
            return;
        }

        String[] values = (String[]) call(profile, "getGlobalRuleVarByName", new Class<?>[]{String.class}, WHITE_LIST_VAR);
        if (!contains(values, "com.android.vending")) {
            boolean appended = (Boolean) call(profile, "appendGlobalRuleVar", new Class<?>[]{String.class, String[].class},
                    WHITE_LIST_VAR, new String[]{"com.android.vending"});
            System.out.println("Appended com.android.vending to " + WHITE_LIST_VAR + "=" + appended);
        } else {
            System.out.println("Global var " + WHITE_LIST_VAR + " exists");
        }
    }

    private static boolean contains(String[] values, String value) {
        if (values == null) {
            return false;
        }
        for (String item : values) {
            if (value.equals(item)) {
                return true;
            }
        }
        return false;
    }

    private static void deleteByName(Object profile, String name) throws Exception {
        Object rule = call(profile, "getRuleByName", new Class<?>[]{String.class}, name);
        if (rule != null) {
            int id = (Integer) call(rule, "getId");
            call(profile, "deleteRule", new Class<?>[]{int.class}, id);
            System.out.println("Deleted old rule id=" + id + " name=" + name);
        }
    }

    private static Object call(Object target, String method) throws Exception {
        return target.getClass().getMethod(method).invoke(target);
    }

    private static Object call(Object target, String method, Class<?>[] types, Object... args) throws Exception {
        return target.getClass().getMethod(method, types).invoke(target, args);
    }
}
