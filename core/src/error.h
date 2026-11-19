/*
 * error.h: the one exception type inside the core.  Anything that cannot go on throws bk::Error
 * with a plain sentence; the C API (api.cpp) and the worker catch it, log it and refuse.  Nothing
 * is thrown across beatkey.h and nothing is thrown on the audio thread (it runs no code that can).
 */
#ifndef BK_ERROR_H
#define BK_ERROR_H

#include <stdexcept>
#include <string>

namespace bk {

struct Error : std::runtime_error {
    explicit Error(const std::string &what) : std::runtime_error(what) {}
};

}  // namespace bk

#endif
