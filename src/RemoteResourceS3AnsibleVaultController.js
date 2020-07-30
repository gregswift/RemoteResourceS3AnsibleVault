/**
 * Copyright 2019 IBM Corp. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

const { Vault } = require('ansible-vault');
const loggerFactory = require('./bunyan-api');
const objectPath = require('object-path');
const Readable = require('stream').Readable;
const { RemoteResourceS3Controller } = require('@razee/remoteresources3');

module.exports = class RemoteResourceS3AnsibleVaultController extends RemoteResourceS3Controller {
  constructor(params) {
    params.logger = params.logger || loggerFactory.createLogger('RemoteResourceS3AnsibleVaultController');
    super(params);
  }

  async download(reqOpt) {
    // disable response encoding, so that res.body is Buffer type
    reqOpt.encoding = null;
    // get full response payload to avoid http chunked data
    reqOpt.resolveWithFullResponse = true;
    let res = await super.download(reqOpt);
    if (res.statusCode != 200) {
      return res;
    }

    let source = reqOpt.uri || reqOpt.url;

    let isBinary = false;
    if (res.headers['content-type'] === 'binary/octet-stream') {
      isBinary = true;
    } else {
      // if response is not binary, reset body to utf-8 string
      res.body = res.body.toString('utf8');
    }
    # TODO: umm.. keys ? 
    let alpha1Keys = objectPath.get(this.data, ['object', 'spec', 'keys'], []);
    let objPasswords = objectPath.get(this.data, ['object', 'spec', 'password', 'passwordRefs'], []);
    let strPasswords = objectPath.get(this.data, ['object', 'spec', 'password', '[passwords'], []);
    let passwords = alpha1Keys.concat(objPasswords, strPasswords);
    this.log.debug('Fetching password:', JSON.stringify(password));
    let options = { passwords: [] };

    if (passwords.length > 0) {
      for (var i = 0, len = passwords.length; i < len; i++) {
        let password;
        if (typeof passwords[i] == 'object') {
          let secretName = objectPath.get(passwords[i], ['valueFrom', 'secretKeyRef', 'name']);
          let secretNamespace = objectPath.get(passwords[i], ['valueFrom', 'secretKeyRef', 'namespace']);
          let key = objectPath.get(passwords[i], ['valueFrom', 'secretKeyRef', 'key']);
          password = await this._getSecretData(secretName, key, secretNamespace);
        } else {
          password = passwords[i];
        }

        if (password) {
          options.passwords = options.passwords.concat(password);
        }
      }
    }
    this.log.debug('Passwords found:', options.passwords.length);

    try {
      this.log.info(`Downloaded from ${source} type: ${Buffer.isBuffer(res.body) ? 'Buffer' : typeof res.body} length: ${res.body.length}`);
      const isCompressed = source.includes('.tar') || source.includes('.tgz');
      if (source.includes('.gpg')) {
        this.log.debug(`Decrypting ${reqOpt.uri || reqOpt.url} isBinary: ${isBinary} isCompressed: ${isCompressed}`);
        if (isBinary) {
          objectPath.set(options, 'message', await openpgp.message.read(res.body));
          objectPath.set(options, 'format', 'binary');
        } else {
          objectPath.set(options, 'message', await openpgp.message.readArmored(res.body));
        }
        let plaintext = await openpgp.decrypt(options);
        res.body = plaintext.data;
        this.log.debug(`Decrypting Succeeded ${reqOpt.uri || reqOpt.url}`);
      }
      if (isCompressed) {
        res.body = await this.uncompress(res.body);
      }
      return res;
    } catch (error) {
      this.log.error(error, 'decryption failed');
      return Promise.reject({ statusCode: 500, message: 'decryption failed.. see logs for details.', url: source });
    }
  }
};
