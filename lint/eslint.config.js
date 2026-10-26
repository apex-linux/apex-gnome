// SPDX-FileCopyrightText: 2025 Florian Müllner <fmuellner@gnome.org>
// SPDX-License-Identifier: MIT OR LGPL-2.1-or-later
// gnome-shell 51.0's eslint.config.js; the files, the ignores and the last block are Apex's.

import {defineConfig} from '@eslint/config-helpers';
import gnome from 'eslint-config-gnome';

export default defineConfig([
    gnome.configs.recommended,
    gnome.configs.jsdoc,
    {
        rules: {
            camelcase: ['error', {
                properties: 'never',
            }],
            'consistent-return': 'error',
            'eqeqeq': ['error', 'smart'],
            'key-spacing': ['error', {
                mode: 'minimum',
                beforeColon: false,
                afterColon: true,
            }],
            'prefer-arrow-callback': 'error',
            'prefer-const': ['error', {
                destructuring: 'all',
            }],
            'jsdoc/require-param-description': 'off',
            'jsdoc/require-jsdoc': ['error', {
                exemptEmptyFunctions: true,
                publicOnly: {
                    esm: true,
                },
            }],
        },
    }, {
        files: [
            'desktop/shell/js/**',
            'tests/layer/probe.js',
            'tests/shots/probe.js',
            'tests/shots/glass.js',
            'tests/shots/a11y.js',
            'tests/shots/backdrop.js',
            'tests/shots/indicators.js',
            'tests/shots/idle.js',
            'tests/shots/dock-dnd.js',
            'tests/shots/dock-external.js',
            'tests/shots/glass-load.js',
            'tests/shots/load-window.js',
            'tests/laptop/scenarios.js',
        ],
        languageOptions: {
            globals: {
                global: 'readonly',
                _: 'readonly',
                C_: 'readonly',
                N_: 'readonly',
                ngettext: 'readonly',
            },
        },
    }, {
        // apex-lint's comment budget (CONTRIBUTING) wins over a JSDoc block per export.
        rules: {
            'jsdoc/require-jsdoc': 'off',
        },
    },
]);
