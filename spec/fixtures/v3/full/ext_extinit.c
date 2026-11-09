#include "ruby/ruby.h"

#define init(func, name) {	\
    extern void func(void);	\
    ruby_init_ext(name".so", func); \
}

void ruby_init_ext(const char *name, void (*init)(void));

void Init_ext(void)
{
    init(Init_bigdecimal, "bigdecimal");
    init(Init_cgi_escape, "cgi/escape");
    init(Init_continuation, "continuation");
    init(Init_coverage, "coverage");
    init(Init_date_core, "date_core");
    init(Init_digest, "digest");
    init(Init_digest_bubblebabble, "digest/bubblebabble");
    init(Init_digest_md5, "digest/md5");
    init(Init_digest_rmd160, "digest/rmd160");
    init(Init_digest_sha1, "digest/sha1");
    init(Init_digest_sha2, "digest/sha2");
    init(Init_etc, "etc");
    init(Init_fcntl, "fcntl");
    init(Init_json_ext_generator, "json/ext/generator");
    init(Init_json_ext_parser, "json/ext/parser");
    init(Init_monitor, "monitor");
    init(Init_nkf, "nkf");
    init(Init_objspace, "objspace");
    init(Init_openssl, "openssl");
    init(Init_pathname, "pathname");
    init(Init_psych, "psych");
    init(Init_rbconfig_sizeof, "rbconfig/sizeof");
    init(Init_ripper, "ripper");
    init(Init_stringio, "stringio");
    init(Init_strscan, "strscan");
    init(Init_zlib, "zlib");
}
