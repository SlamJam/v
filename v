#!/usr/bin/env python3
from argparse import ArgumentParser
from json import dump as json_marshal, dumps as json_marshal_str
from sys import stdin, stdout, stderr
from os.path import isabs, expanduser, join as pjoin, exists, dirname
from os import environ, makedirs, listdir, chmod, stat
from shutil import which, copyfile, rmtree
from hashlib import sha1
from subprocess import Popen as Subprocess, PIPE as pipe

subprocess_streams = {
    "stdin" : stdin,
    "stdout": stderr,
    "stderr": stderr,
}


class Logger(object):
    DEBUG = 0
    INFO  = 1
    ERROR = 2
    OFF   = 3

    level_strings = {
        0: "debug",
        1: "info",
        2: "error",
        3: "off"
    }

    def __init__(self, presenter, level=INFO):
        self.presenter = presenter
        self.level = level
    def level_string(self, level):
        return self.level_strings[level]
    def message(self, level, message, **kwargs):
        if level >= self.level:
            self.presenter.show(
                "log",
                {
                    "level": self.level_string(level),
                    "message": message,
                    "arguments": kwargs
                }
            )
    def debug(self, msg, **kwargs):
        return self.message(self.DEBUG, msg, **kwargs)
    def info(self, msg, **kwargs):
        return self.message(self.INFO, msg, **kwargs)
    def error(self, msg, **kwargs):
        return self.message(self.ERROR, msg, **kwargs)

class Presenter(object):

    class JSON(object):

        def show(self, data):
            json_marshal(
                data,
                stdout,
                ensure_ascii=False,
                sort_keys=True
            )
            stdout.write("\n")

    class Text(object):

        def show(self, data):
            t = data["type"]
            payload = data["payload"]
            if t == "operation":
                name = payload["name"]
                result = payload["result"]
                if name == "show":
                    json_marshal(
                        result,
                        stdout,
                        indent=4,
                        sort_keys=True
                    )
                    stdout.write("\n")
                elif name == "install":
                    stdout.write(
                        "Installed {} version {} into {}\n".format(
                            result["toolchain"],
                            result["version"],
                            result["dir"]
                        )
                    )
                elif name == "uninstall":
                    stdout.write(
                        "Uninstalled {} version {} from {}\n".format(
                            result["toolchain"],
                            result["version"],
                            result["dir"]
                        )
                    )
                elif name == "environment":
                    for k, v in result.items():
                        stdout.write(
                            "export {}='{}'".format(k, v) + "\n"
                        )
                elif name == "local":
                    stdout.write(
                        "Locally installed versions of {}:\n".format(
                            result["toolchain"]
                        )
                    )
                    for version in result["versions"]:
                        stdout.write("  - {}\n".format(version))
                    if len(result["versions"]) == 0 and result["query"]:
                        exit(1)
                elif name == "remote":
                    stdout.write(
                        "Remote versions(not installed) of {}:\n".format(
                            result["toolchain"]
                        )
                    )
                    for version in result["versions"]:
                        stdout.write("  - {}\n".format(version))
                    if len(result["versions"]) == 0 and result["query"]:
                        exit(1)
            elif t == "log":
                stderr.write(
                    "{0} {1}\n".format(
                        payload["message"],
                        json_marshal_str(
                            payload["arguments"],
                            indent=4,
                            sort_keys=True
                        ) if len(payload["arguments"]) else ""
                    )
                )

    presenters = {
        "json": JSON,
        "text": Text,
    }

    def __init__(self, presenter):
        name = presenter.lower().strip()
        if name not in self.presenters:
            raise KeyError(
                "Unsupported presenter '{}'".format(
                    name
                )
            )
        self.presenter = self.presenters[name]()

    def show(self, type, payload):
        return self.presenter.show({
            "type": type,
            "payload": payload
        })

class Params(object):

    default = {
        "V_PREFIX": expanduser("~/.v")
    }

    def __init__(self, raw_params, environ=environ):
        params = self.default.copy()
        params.update(environ)
        params.update(self.parse(raw_params))
        self.params = params

    def __dict__(self):
        return self.params

    def get_prefix(self):
        return self.params["V_PREFIX"]

    def parse(self, raw_params):
        res = {}
        if not raw_params:
            return res
        for v in raw_params:
            key, value = v.split("=", 1)
            res[key] = value
        return res

class Provider(object):

    class Git(object):

        def __init__(self, toolchain):
            self.toolchain = toolchain

        def provide(self, v, update=True):
            root = pjoin(
                self.toolchain.get_cache_dir(),
                identify(v)
            )

            if exists(root):
                if update:
                    git(
                        ["pull", "-r"],
                        cwd=root
                    )
            else:
                makedirs(
                    dirname(root),
                    exist_ok=True
                )
                git(["clone", v, root])
            return root

    providers = {
        "git": Git,
    }

    def __init__(self, name, params):
        if name not in self.providers:
            raise KeyError(
                "Unsupported provider '{}'".format(
                    name
                )
            )
        self.provider = self.providers[name](params)

    def provide(self, v, update=True):
        return self.provider.provide(v, update=update)

class Toolchain(object):

    class Base(object):

        def __init__(self, name, params, log):
            self.name   = name
            self.params = params
            self.log    = log

        def get_prefix(self):
            return pjoin(
                self.params.get_prefix(),
                "toolchain",
                self.name
            )

        def get_dir(self, version):
            return pjoin(
                self.get_prefix(),
                version
            )

        def get_build_dir(self, version):
            return pjoin(
                self.get_dir(version),
                "build"
            )

        def get_bin_dir(self, version):
            return pjoin(
                self.get_dir(version),
                "bin"
            )

        def get_cache_dir(self):
            return pjoin(
                self.params.get_prefix(),
                "cache"
            )

    class Go(Base):

        def __init__(self, *args, **kwargs):
            super(
                Toolchain.Go,
                self
            ).__init__(*args, **kwargs)
            self.repo_url = "https://github.com/golang/go"
            self.repo = Provider(
                "git",
                self
            ).provide(self.repo_url)

        def show(self, version):
            tag = "go" + version
            return {
                "tag": tag,
                "repo": self.repo_url,
                "tarball": "https://codeload.github.com/golang/go/tar.gz/" + tag,
                "installed": self.installed(version),
                "environment": self.environment(version)
            }

        def installed(self, version):
            return exists(self.get_dir(version))

        def install(self, version):
            makedirs(
                self.get_dir(version),
                exist_ok=True
            )

            build_dir = self.get_build_dir(version)
            rmtree(build_dir, ignore_errors=True)
            makedirs(build_dir, exist_ok=True)
            self.log.info("Clonning repository from cache...")
            git(
                [
                    "clone",
                    "-b", "go{}".format(version),
                    "file://{}/.git".format(self.repo),
                    build_dir
                ],
                cwd=build_dir
            )

            env = environ.copy()
            env.update(self.environment(version))

            self.log.info("Performing the build...")
            run_check(
                pjoin(build_dir, "src/make.bash"),
                [],
                cwd=pjoin(build_dir, "src"),
                env=env
            )
            makedirs(
                self.get_bin_dir(version),
                exist_ok=True
            )

            self.log.info("Syncing binaries...")
            bin = pjoin(build_dir, "bin")
            for binary in listdir(bin):
                target = pjoin(self.get_bin_dir(version), binary)
                copyfile(
                    pjoin(bin, binary),
                    target
                )
                chmod(
                    target,
                    0o755
                )

            return {
                "toolchain": self.name,
                "version": version,
                "dir": self.get_dir(version)
            }

        def uninstall(self, version):
            rmtree(self.get_dir(version))
            return {
                "toolchain": self.name,
                "version": version,
                "dir": self.get_dir(version)
            }

        def environment(self, version):
            bootstrap_root_default = "/usr/lib/golang"
            bootstrap_root = environ.get(
                "GOROOT",
                bootstrap_root_default
            )
            if bootstrap_root.startswith(self.get_prefix()):
                bootstrap_root = bootstrap_root_default

            return {
                "GOROOT_BOOTSTRAP": bootstrap_root,
                "GOROOT": self.get_build_dir(version),
                "PATH": ":".join(
                    [self.get_bin_dir(version)] + [
                        path
                        for path in environ.get("PATH", "").split(":")
                        if not path.startswith(self.get_prefix())
                    ]
                )
            }

        def versions(self):
            repo_path = pjoin(
                self.repo,
                ".git"
            )
            process = git(["--git-dir=" + repo_path, "tag"])
            output = process.communicate()[0]
            return [
                line.strip().replace("go", "", 1)
                for line in output.decode("utf8").split("\n")
                if line.startswith("go")
            ]

    toolchains = {
        "go": Go
    }
    operations = [
        "show",
        "install",
        "uninstall",
        "environment",
        "remote",
        "local",
    ]
    def __init__(self, name, params, log):
        if name not in self.toolchains:
            raise KeyError(
                "Unsupported toolchain '{}'".format(
                    name
                )
            )
        self.name = name
        self.toolchain = self.toolchains[name](name, params, log)
    def assert_installed(self, version):
        if not self.toolchain.installed(version):
            raise RuntimeError(
                "Version '{}' of '{}' is not installed".format(
                    version,
                    self.toolchain.name
                )
            )
    def assert_not_installed(self, version):
        if self.toolchain.installed(version):
            raise RuntimeError(
                "Version '{}' of '{}' already installed at '{}'".format(
                    version,
                    self.toolchain.name,
                    self.toolchain.get_dir(version)
                )
            )
    def show(self, version):
        assert version
        return self.toolchain.show(version)
    def install(self, version):
        assert version
        self.assert_not_installed(version)
        return self.toolchain.install(version)
    def uninstall(self, version):
        assert version
        return self.toolchain.uninstall(version)
    def environment(self, version):
        assert version
        self.assert_installed(version)
        return self.toolchain.environment(version)
    def remote(self, version_query):
        return {
            "toolchain": self.name,
            "query": version_query,
            "versions": self.version_query(
                [
                    v
                    for v in self.toolchain.versions()
                    if not self.toolchain.installed(v)
                ],
                version_query
            )
        }
    def local(self, version_query):
        return {
            "toolchain": self.name,
            "query": version_query,
            "versions": self.version_query(
                [
                    v
                    for v in self.toolchain.versions()
                    if self.toolchain.installed(v)
                ],
                version_query
            )
        }
    def version_query(self, versions, version_query):
        return [
            version
            for version in versions
            if has_prefix(version, version_query)
        ]

def run(executable, arguments, streams=subprocess_streams, **kwargs):
    path = executable
    if not isabs(executable):
        path = which(executable)

    nkwargs = kwargs.copy()
    nkwargs.update(streams)
    return Subprocess(
        [path] + arguments,
        **nkwargs
    )

def run_check(*args, **kwargs):
    process = run(
        *args,
        streams={
            "stdin": stdin,
            "stdout": pipe,
            "stderr": pipe
        },
        **kwargs
    )
    code = process.wait()
    if code != 0:
        _, err = process.communicate()
        raise RuntimeError(
            "Command '{}' exited with '{}' code and stderr: {}".format(
                args,
                code,
                err.decode("utf8")
            )
        )
    return process

def git(arguments, **kwargs):
    return run_check(
        "git",
        arguments,
        **kwargs
    )

def identify(s):
    h = sha1()
    h.update(s.encode("utf8"))
    return h.hexdigest()

def has_prefix(v, prefix):
    return v == prefix or v.startswith(prefix or "")

def main(args):
    params    = Params(args["param"])
    presenter = Presenter(args["presenter"])
    log       = Logger(
        presenter,
        Logger.DEBUG if args["debug"] else Logger.INFO
    )
    toolchain = Toolchain(args["toolchain"], params, log)

    if args["operation"] not in Toolchain.operations:
        raise KeyError(
            "Unsupported operation '{}' on {} toolchain".format(
                args["operation"],
                toolchain.name
            )
        )

    log.debug(
        "Running",
        operation=args["operation"],
        toolchain=args["toolchain"],
        version=args["version"]
    )
    presenter.show(
        "operation",
        {
            "name": args["operation"],
            "arguments": args,
            "result": getattr(
                toolchain,
                args["operation"]
            )(
                args["version"]
            )
        }
    )


if __name__ == "__main__":
    p = ArgumentParser()
    p.add_argument(
        "toolchain",
        help="Name of the toolchain to operate on, available toolchains are: {}".format(
            [k for k, _ in Toolchain.toolchains.items()]
        )
    )
    p.add_argument(
        "operation",
        help="Operation name to perform on a toolchain, available operations are: {}".format(
            Toolchain.operations
        )
    )
    p.add_argument(
        "version",
        help="Version to apply operation to",
        nargs="?"
    )
    p.add_argument(
        "--debug",
        help="Enable debug mode",
        action="store_true"
    )
    p.add_argument(
        "--presenter",
        help="Output presenter, available are: {}".format(
            [k for k, _ in Presenter.presenters.items()]
        ),
        default="text"
    )
    p.add_argument(
        "--param",
        help="Set param(in a format `--param=key=value`) for requested operation",
        nargs="+"
    )

    def match(full, part):
        vs = [
            v
            for v in full
            if has_prefix(v, part)
        ]
        if len(vs) == 0:
            return part
        if len(vs) > 1:
            raise RuntimeError(
                "Ambiguous name '{}', did you mean one of these? {}".format(
                    part,
                    vs
                )
            )
        return vs[0]

    def normalize(args):
        nargs = args.copy()
        nargs["toolchain"] = match(Toolchain.toolchains, args["toolchain"].lower().strip())
        nargs["operation"] = match(Toolchain.operations, args["operation"].lower().strip())
        return nargs

    main(
        normalize(
            p.parse_args().__dict__
        )
    )
