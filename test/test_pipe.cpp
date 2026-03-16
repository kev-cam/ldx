/*
 * test_pipe.cpp — Test the Pipe<Args, Ret> abstraction.
 *
 * Proves:
 * 1. Default pipe is a transparent passthrough (same result as direct call)
 * 2. Args struct captures all arguments by value
 * 3. Subclass can intercept/modify write and propagate
 * 4. C interface works for type-erased access
 * 5. Integration with ldx GOT patching (pipe replaces a live function)
 */

#include <cstdio>
#include <cstring>
#include <cmath>
#include <vector>
#include "../src/ldx_pipe.h"

extern "C" {
#include "../src/ldx.h"
}

static int failures = 0;

static void check(bool cond, const char *name, const char *msg) {
    if (cond) {
        printf("%s: PASS\n", name);
    } else {
        printf("%s: FAIL (%s)\n", name, msg);
        failures++;
    }
}

/* ---- Arg structs for test functions ---- */

/* strlen(const char *s) -> size_t */
struct StrlenArgs {
    const char *s;

    size_t invoke(void *fn) const {
        return ((size_t(*)(const char *))fn)(s);
    }
};

/* double compute(double x, double y) -> double */
static double compute(double x, double y) {
    return sqrt(x * x + y * y);
}

struct ComputeArgs {
    double x, y;

    double invoke(void *fn) const {
        return ((double(*)(double, double))fn)(x, y);
    }
};

/* void vec3_scale(double *v, int n, double factor) */
static void vec3_scale(double *v, int n, double factor) {
    for (int i = 0; i < n; i++)
        v[i] *= factor;
}

struct Vec3ScaleArgs {
    double *v;
    int n;
    double factor;

    void invoke(void *fn) const {
        ((void(*)(double *, int, double))fn)(v, n, factor);
    }
};

/* ---- Test 1: basic passthrough ---- */

static void test_passthrough() {
    /* Create a pipe for strlen. */
    ldx::Pipe<StrlenArgs, size_t> pipe((void *)strlen);

    size_t direct = strlen("hello world");
    size_t piped = pipe.call(StrlenArgs{"hello world"});

    check(direct == piped && piped == 11,
          "test_passthrough",
          "strlen through pipe should match direct call");
}

/* ---- Test 2: floating-point args and return ---- */

static void test_float_args() {
    ldx::Pipe<ComputeArgs, double> pipe((void *)compute);

    double direct = compute(3.0, 4.0);
    double piped = pipe.call(ComputeArgs{3.0, 4.0});

    check(fabs(direct - piped) < 1e-15 && fabs(piped - 5.0) < 1e-15,
          "test_float_args",
          "compute(3,4) should equal 5.0");
}

/* ---- Test 3: void return, pointer arg ---- */

static void test_void_pipe() {
    ldx::Pipe<Vec3ScaleArgs, void> pipe((void *)vec3_scale);

    double v1[] = {2.0, 4.0, 6.0};
    double v2[] = {2.0, 4.0, 6.0};

    vec3_scale(v1, 3, 0.5);               /* direct */
    pipe.call(Vec3ScaleArgs{v2, 3, 0.5}); /* piped */

    check(v1[0] == v2[0] && v1[1] == v2[1] && v1[2] == v2[2],
          "test_void_pipe",
          "void pipe should produce same side effects");
}

/* ---- Test 4: subclass that records calls ---- */

template<typename Args, typename Ret>
class RecordingPipe : public ldx::Pipe<Args, Ret> {
public:
    using ldx::Pipe<Args, Ret>::Pipe;

    struct Record {
        Args args;
        Ret result;
    };

    std::vector<Record> log;

    void write(const Args &args) override {
        ldx::Pipe<Args, Ret>::write(args);
        /* Could serialize here for network transport. */
    }

    Ret propagate() override {
        Ret r = ldx::Pipe<Args, Ret>::propagate();
        log.push_back({this->stored_, r});
        return r;
    }
};

static void test_recording() {
    RecordingPipe<ComputeArgs, double> pipe((void *)compute);

    pipe.call(ComputeArgs{3.0, 4.0});
    pipe.call(ComputeArgs{5.0, 12.0});
    pipe.call(ComputeArgs{8.0, 15.0});

    bool ok = (pipe.log.size() == 3 &&
               fabs(pipe.log[0].result - 5.0) < 1e-15 &&
               fabs(pipe.log[1].result - 13.0) < 1e-15 &&
               fabs(pipe.log[2].result - 17.0) < 1e-15 &&
               pipe.log[0].args.x == 3.0 &&
               pipe.log[1].args.x == 5.0);

    check(ok, "test_recording",
          "recording pipe should capture args and results");

    if (ok) {
        printf("  recorded %zu calls:\n", pipe.log.size());
        for (auto &r : pipe.log)
            printf("    compute(%g, %g) = %g\n", r.args.x, r.args.y, r.result);
    }
}

/* ---- Test 5: subclass that transforms args ---- */

class ScalingPipe : public ldx::Pipe<ComputeArgs, double> {
public:
    double scale_factor;

    ScalingPipe(void *fn, double sf)
        : ldx::Pipe<ComputeArgs, double>(fn), scale_factor(sf) {}

    void write(const ComputeArgs &args) override {
        /* Transform args before storing — scale both inputs. */
        ComputeArgs scaled{args.x * scale_factor, args.y * scale_factor};
        ldx::Pipe<ComputeArgs, double>::write(scaled);
    }
};

static void test_transform() {
    ScalingPipe pipe((void *)compute, 2.0);

    /* compute(3,4) normally = 5.  With 2x scaling: compute(6,8) = 10. */
    double r = pipe.call(ComputeArgs{3.0, 4.0});

    check(fabs(r - 10.0) < 1e-15,
          "test_transform",
          "scaling pipe should transform args before propagation");
}

/* ---- Test 6: C interface ---- */

static void test_c_interface() {
    auto *pipe = new ldx::Pipe<ComputeArgs, double>((void *)compute);
    ldx_pipe_handle_t *h = ldx_pipe_wrap(pipe);

    ComputeArgs args{3.0, 4.0};
    ldx_pipe_write(h, &args, sizeof(args));

    double result = 0;
    ldx_pipe_propagate(h, &result, sizeof(result));

    check(fabs(result - 5.0) < 1e-15,
          "test_c_interface",
          "C interface should work with type-erased pipe");

    /* Verify stored args are accessible. */
    size_t sz = 0;
    const void *stored = ldx_pipe_args(h, &sz);
    check(sz == sizeof(ComputeArgs) && stored != nullptr,
          "test_c_args_access",
          "should be able to read stored args via C interface");

    ldx_pipe_destroy(h);
}

/* ---- Test 7: GOT integration — pipe replaces a live function ---- */

static ldx::Pipe<StrlenArgs, size_t> *live_pipe = nullptr;

static size_t strlen_via_pipe(const char *s) {
    return live_pipe->call(StrlenArgs{s});
}

static void test_got_integration() {
    /* Save real strlen, create pipe, install replacement. */
    void *orig = dlreplace("strlen", (void *)strlen_via_pipe);

    live_pipe = new ldx::Pipe<StrlenArgs, size_t>(orig);

    volatile size_t len = strlen("piped!");
    check(len == 6,
          "test_got_integration",
          "strlen through GOT-patched pipe should work");

    /* Check that the pipe actually stored the args. */
    const StrlenArgs &stored = live_pipe->stored();
    check(strcmp(stored.s, "piped!") == 0,
          "test_got_stored_args",
          "pipe should have captured the args");

    /* Restore original. */
    dlreplace("strlen", orig);
    delete live_pipe;
    live_pipe = nullptr;
}

/* ---- main ---- */

int main() {
    printf("=== ldx pipe tests ===\n");

    test_passthrough();
    test_float_args();
    test_void_pipe();
    test_recording();
    test_transform();
    test_c_interface();
    test_got_integration();

    printf("=== %d failure(s) ===\n", failures);
    return failures ? 1 : 0;
}
