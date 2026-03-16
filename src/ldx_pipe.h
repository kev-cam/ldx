#ifndef LDX_PIPE_H
#define LDX_PIPE_H

/*
 * ldx_pipe.h — Templated pipe for function call forwarding.
 *
 * A Pipe<Args, Ret> is an intermediary between a call site and the
 * actual function.  The original call arguments are packed into an
 * Args struct, written into the pipe, and propagated to the other end.
 *
 * Default behavior (depth=1): passthrough — propagate() calls the
 * original function immediately.  Subclass and override write/propagate
 * to add serialization, network transport, buffering, etc.
 *
 * Args struct contract:
 *   - POD struct holding all function arguments by value
 *   - Must define: Ret invoke(void *fn) const;
 *     (casts fn to the correct signature and calls it with stored args)
 */

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace ldx {

/* Base class for type-erased pipe operations (for C/Python interop). */
class PipeBase {
public:
    virtual ~PipeBase() = default;

    /* Write raw args into the pipe. */
    virtual void write_raw(const void *args, size_t size) = 0;

    /* Execute the stored call.  Returns raw result bytes. */
    virtual void propagate_raw(void *ret_buf, size_t ret_size) = 0;

    /* Get the stored args buffer. */
    virtual const void *args_data() const = 0;
    virtual size_t args_size() const = 0;

    /* Pipe depth (how many calls can be in-flight). */
    virtual int depth() const = 0;
};

/* Typed pipe. */
template<typename Args, typename Ret>
class Pipe : public PipeBase {
public:
    using orig_fn_t = void *;  /* opaque; Args::invoke casts it */

    Pipe(void *original, int depth = 1)
        : original_(original), depth_(depth)
    {
        memset(&stored_, 0, sizeof(stored_));
    }

    virtual ~Pipe() = default;

    /* Main entry point: pack args, push through pipe, return result.
     * This replaces the original function call. */
    Ret call(const Args &args) {
        write(args);
        return propagate();
    }

    /* Store args in the pipe.  Override to add serialization,
     * compression, encryption, etc. */
    virtual void write(const Args &args) {
        stored_ = args;
    }

    /* Execute the stored call on the "other side" of the pipe.
     * Default: call the original function locally.
     * Override to send over network, queue for async, etc. */
    virtual Ret propagate() {
        return stored_.invoke(original_);
    }

    /* Access stored args (e.g. for inspection or forwarding). */
    const Args &stored() const { return stored_; }

    /* Swap the original function pointer (e.g. after migration). */
    void set_original(void *fn) { original_ = fn; }
    void *get_original() const { return original_; }

    /* --- PipeBase interface --- */

    void write_raw(const void *args, size_t size) override {
        if (size >= sizeof(Args))
            memcpy(&stored_, args, sizeof(Args));
    }

    void propagate_raw(void *ret_buf, size_t ret_size) override {
        Ret r = propagate();
        if (ret_buf && ret_size >= sizeof(Ret))
            memcpy(ret_buf, &r, sizeof(Ret));
    }

    const void *args_data() const override { return &stored_; }
    size_t args_size() const override { return sizeof(Args); }
    int depth() const override { return depth_; }

protected:
    void *original_;
    int depth_;
    Args stored_;
};

/* Specialization for void return type. */
template<typename Args>
class Pipe<Args, void> : public PipeBase {
public:
    Pipe(void *original, int depth = 1)
        : original_(original), depth_(depth)
    {
        memset(&stored_, 0, sizeof(stored_));
    }

    virtual ~Pipe() = default;

    void call(const Args &args) {
        write(args);
        propagate();
    }

    virtual void write(const Args &args) {
        stored_ = args;
    }

    virtual void propagate() {
        stored_.invoke(original_);
    }

    const Args &stored() const { return stored_; }
    void set_original(void *fn) { original_ = fn; }
    void *get_original() const { return original_; }

    void write_raw(const void *args, size_t size) override {
        if (size >= sizeof(Args))
            memcpy(&stored_, args, sizeof(Args));
    }

    void propagate_raw(void *, size_t) override {
        propagate();
    }

    const void *args_data() const override { return &stored_; }
    size_t args_size() const override { return sizeof(Args); }
    int depth() const override { return depth_; }

protected:
    void *original_;
    int depth_;
    Args stored_;
};

} /* namespace ldx */

/*
 * C interface for integration with existing ldx GOT patching
 * and Python interop.
 */
#ifdef __cplusplus
extern "C" {
#endif

/* Opaque pipe handle. */
typedef struct ldx_pipe_handle ldx_pipe_handle_t;

/* Create a pipe from a type-erased PipeBase pointer.
 * Takes ownership — destroyed via ldx_pipe_destroy. */
ldx_pipe_handle_t *ldx_pipe_wrap(void *pipe_base_ptr);

/* Write raw args into a pipe. */
void ldx_pipe_write(ldx_pipe_handle_t *h, const void *args, size_t size);

/* Propagate and get result. */
void ldx_pipe_propagate(ldx_pipe_handle_t *h, void *ret_buf, size_t ret_size);

/* Get stored args. */
const void *ldx_pipe_args(ldx_pipe_handle_t *h, size_t *size_out);

/* Destroy pipe handle (and the underlying Pipe object). */
void ldx_pipe_destroy(ldx_pipe_handle_t *h);

#ifdef __cplusplus
}
#endif

#endif /* LDX_PIPE_H */
