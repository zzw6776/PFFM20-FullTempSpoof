public class ThanoxApplyStartRules {
    private static final String[] RULES = new String[]{
            "ALLOW com.android.vending com.google.android.gms",
            "ALLOW com.android.vending com.google.android.gsf",
            "ALLOW com.google.android.gms/com.google.android.gms.chimera.GmsBoundBrokerService",
            "ALLOW com.google.android.gms/com.google.android.gms.chimera.PersistentDirectBootAwareApiService",
            "ALLOW com.google.android.gms/com.google.android.gms.chimera.container.GmsModuleProvider",
            "ALLOW com.google.android.gms/com.google.android.gms.gservices.provider.GservicesProvider",
            "DENY * com.google.android.gms",
            "DENY * com.google.android.gsf"
    };

    private static final String[] OBSOLETE_RULES = new String[]{
            "ALLOW com.google.android.gms com.google.android.gms",
            "ALLOW com.google.android.gms com.google.android.gsf",
            "ALLOW com.google.android.gsf com.google.android.gms",
            "ALLOW com.google.android.gsf com.google.android.gsf"
    };

    public static void main(String[] args) throws Exception {
        Class<?> nativeClass = Class.forName("github.tornaco.android.thanos.core.app.ThanosManagerNative");
        Object thanos = nativeClass.getMethod("getDefault").invoke(null);
        if (thanos == null) {
            throw new IllegalStateException("Thanox service not found");
        }
        System.out.println("Thanox: " + call(thanos, "whoAreYou") + " " + call(thanos, "getVersionName"));

        Object activity = call(thanos, "getActivityManager");
        call(activity, "setStartBlockEnabled", new Class<?>[]{boolean.class}, true);
        call(activity, "setStartRuleEnabled", new Class<?>[]{boolean.class}, true);
        setPkgStartBlockEnabled(activity, "com.google.android.gms", true);
        setPkgStartBlockEnabled(activity, "com.google.android.gsf", true);

        System.out.println("Start block enabled: " + call(activity, "isStartBlockEnabled"));
        System.out.println("Start rules enabled: " + call(activity, "isStartRuleEnabled"));
        System.out.println("GMS start blocking: " + isPkgStartBlocking(activity, "com.google.android.gms"));
        System.out.println("GSF start blocking: " + isPkgStartBlocking(activity, "com.google.android.gsf"));

        String[] existing = (String[]) call(activity, "getAllStartRules");
        for (String obsoleteRule : OBSOLETE_RULES) {
            if (contains(existing, obsoleteRule)) {
                call(activity, "deleteStartRule", new Class<?>[]{String.class}, obsoleteRule);
                System.out.println("Deleted obsolete rule: " + obsoleteRule);
            }
        }

        existing = (String[]) call(activity, "getAllStartRules");
        for (String rule : RULES) {
            if (contains(existing, rule)) {
                call(activity, "deleteStartRule", new Class<?>[]{String.class}, rule);
                System.out.println("Deleted duplicate rule: " + rule);
            }
            call(activity, "addStartRule", new Class<?>[]{String.class}, rule);
            System.out.println("Added rule: " + rule);
        }

        String[] finalRules = (String[]) call(activity, "getAllStartRules");
        System.out.println("Final start rules:");
        if (finalRules != null) {
            for (String rule : finalRules) {
                System.out.println(rule);
            }
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

    private static Object call(Object target, String method) throws Exception {
        return target.getClass().getMethod(method).invoke(target);
    }

    private static Object call(Object target, String method, Class<?>[] types, Object... args) throws Exception {
        return target.getClass().getMethod(method, types).invoke(target, args);
    }

    private static void setPkgStartBlockEnabled(Object activity, String pkgName, boolean enabled) throws Exception {
        try {
            call(activity, "setPkgStartBlockEnabled", new Class<?>[]{String.class, boolean.class}, pkgName, enabled);
            return;
        } catch (NoSuchMethodException ignored) {
            Class<?> pkgClass = Class.forName("github.tornaco.android.thanos.core.pm.Pkg");
            Object pkg = pkgClass.getMethod("systemUserPkg", String.class).invoke(null, pkgName);
            call(activity, "setPkgStartBlockEnabled", new Class<?>[]{pkgClass, boolean.class}, pkg, enabled);
        }
    }

    private static Object isPkgStartBlocking(Object activity, String pkgName) throws Exception {
        try {
            return call(activity, "isPkgStartBlocking", new Class<?>[]{String.class}, pkgName);
        } catch (NoSuchMethodException ignored) {
            Class<?> pkgClass = Class.forName("github.tornaco.android.thanos.core.pm.Pkg");
            Object pkg = pkgClass.getMethod("systemUserPkg", String.class).invoke(null, pkgName);
            return call(activity, "isPkgStartBlocking", new Class<?>[]{pkgClass}, pkg);
        }
    }
}
