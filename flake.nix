{
  description = "Hello world flake using uv2nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      uv2nix,
      pyproject-nix,
      pyproject-build-systems,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      # Define the claude-code CLI package
      claudeCode = pkgs.claude-code; # Assuming it's in nixpkgs

      # Script to run both
      runGeminiScript = pkgs.writeShellScript "run-gemini" ''
        # Check for GEMINI_API_KEY
        if [ -z "$GEMINI_API_KEY" ]; then
          echo "Error: GEMINI_API_KEY environment variable is not set."
          echo "Please set it before running: export GEMINI_API_KEY='your_key_here'"
          exit 1
        fi

        # Check for CLAUDE.md
        if [ ! -f "$PWD/CLAUDE.md" ]; then
          echo "Warning: CLAUDE.md not found in the current directory ($PWD)."
          echo "For optimal performance, please copy CLAUDE.md from the flake's source:"
          echo "cp ${self}/CLAUDE.md $PWD/"
          echo "Then re-run 'nix run <url>#gemini'"
          exit 1
        fi

        # Define a log file path
        LOG_FILE="/tmp/gemini-proxy.log" # Or a path in your project, e.g., "$PWD/proxy.log"

        # Find an available port and export it
        export PORT=$(${python}/bin/python -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')

        # Start the proxy service in the background, redirecting its output to a log file
        export GEMINI_API_KEY="$GEMINI_API_KEY" # Pass through API key
        export LOG_LEVEL="WARNING" # Keep this to minimize even the file logs
        ${self.packages.x86_64-linux.proxy}/bin/uvicorn scripts.server:app --host 0.0.0.0 --port $PORT > "$LOG_FILE" 2>&1 & # Redirect stdout and stderr
        PROXY_PID=$!
        echo "Gemini proxy service started on port $PORT with PID $PROXY_PID. Logs redirected to $LOG_FILE"

        # Wait for the proxy to be ready (optional, but good practice)
        sleep 5 # Simple wait, could be more robust with health check

        # Launch claude-code
        export ANTHROPIC_BASE_URL="http://localhost:$PORT"
        echo "Launching claude-code..."
        ${claudeCode}/bin/claude "$@" # Pass through any arguments to claude

        # Clean up proxy service on exit
        echo "Stopping Gemini proxy service (PID $PROXY_PID)..."
        kill $PROXY_PID
      '';

      # Load a uv workspace from a workspace root.
      # Uv2nix treats all uv projects as workspace projects.
      workspace = uv2nix.lib.workspace.loadWorkspace {
        workspaceRoot = ./.;
      };

      # Create package overlay from workspace.
      overlay = workspace.mkPyprojectOverlay {
        # Prefer prebuilt binary wheels as a package source.
        # Sdists are less likely to "just work" because of the metadata missing from uv.lock.
        # Binary wheels are more likely to, but may still require overrides for library dependencies.
        sourcePreference = "wheel"; # or sourcePreference = "sdist";
        # Optionally customise PEP 508 environment
        # environ = {
        #   platform_release = "5.10.65";
        # };
      };

      # Extend generated overlay with build fixups
      #
      # Uv2nix can only work with what it has, and uv.lock is missing essential metadata to perform some builds.
      # This is an additional overlay implementing build fixups.
      # See:
      # - https://pyproject-nix.github.io/pyproject.nix/build.html
      pyprojectOverrides = final: prev: {
        # Implement build fixups here.
        # Note that uv2nix is _not_ using Nixpkgs buildPythonPackage.
        # It's using https://pyproject-nix.github.io/pyproject.nix/build.html

        # Fix file collision between fastapi and fastapi-cli
        fastapi-cli = prev.fastapi-cli.overrideAttrs (oldAttrs: {
          postInstall = ''
            rm $out/bin/fastapi
          '';
        });
      };

      # This example is only using x86_64-linux
      pkgs = nixpkgs.legacyPackages.x86_64-linux;

      # Use Python 3.12 from nixpkgs
      python = pkgs.python312;

      # Construct package set
      pythonSet =
        # Use base package set from pyproject.nix builders
        (pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
        }).overrideScope
          (
            lib.composeManyExtensions [
              pyproject-build-systems.overlays.default
              overlay
              pyprojectOverrides
            ]
          );
    in
    {
      packages.x86_64-linux = {
        proxy = pythonSet.mkVirtualEnv "gemini-code-flake-env" workspace.deps.default;
        gemini = runGeminiScript; # New package for the combined app
        default = self.packages.x86_64-linux.proxy;
      };

      apps.x86_64-linux = {
        proxy = {
          type = "app";
          program = "${self.packages.x86_64-linux.proxy}/bin/server";
        };
        gemini = {
          type = "app";
          program = "${runGeminiScript}";
        };
      };

      # This example provides two different modes of development:
      # - Impurely using uv to manage virtual environments
      # - Pure development using uv2nix to manage virtual environments
      devShells.x86_64-linux = {
        # It is of course perfectly OK to keep using an impure virtualenv workflow and only use uv2nix to build packages.
        # This devShell simply adds Python and undoes the dependency leakage done by Nixpkgs Python infrastructure.
        impure = pkgs.mkShell {
          packages = [
            python
            pkgs.uv
          ];
          env =
            {
              # Prevent uv from managing Python downloads
              UV_PYTHON_DOWNLOADS = "never";
              # Force uv to use nixpkgs Python interpreter
              UV_PYTHON = python.interpreter;
            }
            // lib.optionalAttrs pkgs.stdenv.isLinux {
              # Python libraries often load native shared objects using dlopen(3).
              # Setting LD_LIBRARY_PATH makes the dynamic library loader aware of libraries without using RPATH for lookup.
              LD_LIBRARY_PATH = lib.makeLibraryPath pkgs.pythonManylinuxPackages.manylinux1;
            };
          shellHook = ''
            unset PYTHONPATH
          '';
        };

        # This devShell uses uv2nix to construct a virtual environment purely from Nix, using the same dependency specification as the application.
        # The notable difference is that we also apply another overlay here enabling editable mode ( https://setuptools.pypa.io/en/latest/userguide/development_mode.html ).
        #
        # This means that any changes done to your local files do not require a rebuild.
        #
        # Note: Editable package support is still unstable and subject to change.
        uv2nix =
          let
            # Create an overlay enabling editable mode for all local dependencies.
            editableOverlay = workspace.mkEditablePyprojectOverlay {
              # Use environment variable
              root = "$REPO_ROOT";
              # Optional: Only enable editable for these packages
              # members = [ "gemini-code-flake" ]; # Changed from hello-world
            };

            # Override previous set with our overrideable overlay.
            editablePythonSet = pythonSet.overrideScope (
              lib.composeManyExtensions [
                editableOverlay

                # Apply fixups for building an editable package of your workspace packages
                (final: prev: {
                  gemini-code-flake = prev.gemini-code-flake.overrideAttrs (old: { # Changed from hello-world
                    # It's a good idea to filter the sources going into an editable build
                    # so the editable package doesn't have to be rebuilt on every change.
                    src = lib.fileset.toSource {
                      root = old.src;
                      fileset = lib.fileset.unions [
                        (old.src + "/pyproject.toml")
                        (old.src + "/README.md")
                        (old.src + "/scripts/server.py") # Changed from src/hello_world/__init__.py
                        # (old.src + "/uv.lock") # Seems to be making nix parse the uv.lock as a .toml, breaking the build process.
                      ];
                    };

                    # Hatchling (our build system) has a dependency on the `editables` package when building editables.
                    #
                    # In normal Python flows this dependency is dynamically handled, and doesn't need to be explicitly declared.
                    # This behaviour is documented in PEP-660.
                    #
                    # With Nix the dependency needs to be explicitly declared.
                    nativeBuildInputs =
                      old.nativeBuildInputs
                      ++ final.resolveBuildSystem {
                        editables = [ ];
                      };
                  });

                })
              ]
            );

            # Build virtual environment, with local packages being editable.
            #
            # Enable all optional dependencies for development.
            virtualenv = editablePythonSet.mkVirtualEnv "gemini-code-flake-dev-env" workspace.deps.all; # Changed from hello-world-dev-env

          in
          pkgs.mkShell {
            packages = [
              virtualenv
              pkgs.uv
            ];

            env = {
              # Don't create venv using uv
              UV_NO_SYNC = "1";

              # Force uv to use Python interpreter from venv
              UV_PYTHON = "${virtualenv}/bin/python";

              # Prevent uv from downloading managed Python's
              UV_PYTHON_DOWNLOADS = "never";
            };

            shellHook = ''
              # Undo dependency propagation by nixpkgs.
              unset PYTHONPATH

              # Get repository root using git. This is expanded at runtime by the editable `.pth` machinery.
              export REPO_ROOT=$(git rev-parse --show-toplevel)
            '';
          };
      };
    };
}
