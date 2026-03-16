#include "ldx_pipe.h"

/* C interface implementation. */

struct ldx_pipe_handle {
    ldx::PipeBase *pipe;
};

extern "C" {

ldx_pipe_handle_t *ldx_pipe_wrap(void *pipe_base_ptr)
{
    auto *h = new ldx_pipe_handle_t;
    h->pipe = static_cast<ldx::PipeBase *>(pipe_base_ptr);
    return h;
}

void ldx_pipe_write(ldx_pipe_handle_t *h, const void *args, size_t size)
{
    if (h && h->pipe)
        h->pipe->write_raw(args, size);
}

void ldx_pipe_propagate(ldx_pipe_handle_t *h, void *ret_buf, size_t ret_size)
{
    if (h && h->pipe)
        h->pipe->propagate_raw(ret_buf, ret_size);
}

const void *ldx_pipe_args(ldx_pipe_handle_t *h, size_t *size_out)
{
    if (!h || !h->pipe) return nullptr;
    if (size_out)
        *size_out = h->pipe->args_size();
    return h->pipe->args_data();
}

void ldx_pipe_destroy(ldx_pipe_handle_t *h)
{
    if (h) {
        delete h->pipe;
        delete h;
    }
}

} /* extern "C" */
