'use strict'
// Compile with solcjs
const fs         = require('fs')
const path       = require('path')
const solc       = require('solc')
const assert     = require('chai').assert
const { keccak } = require('ethereumjs-util')
const { List, Map, Set }
                 = require('immutable')

const { traverseDirs, ensureDir, COMPILES_DIR, ZEPPELIN_SRC_PATH, DEMO_SRC_PATH, fromJS,
        getImmutableKey, setImmutableKey, Logger, getInputsToBuild }
                 = require('@democracy.js/utils')

const LOGGER = new Logger('Compiler')

/**
 * A reusable Compiler for Democracy.js with a search path and custom outputter.
 * @param _startSourcePath {string} a local directory. Can omit the `./` for relative paths.
 * @param _outputter {async function} a (possibly asynchronous) function that
 *        takes (key: string, val: {Map} | {List} | null ) and returns a Promise or
 *        other value that you want returned from `compile` or `clean*` methods.
 *        If missing, _outputter defaults to `setImmutableKey`
 *        to a local file-based DB store.
 */
class Compiler {
  
  constructor(_startSourcePath, _inputter, _outputter) {
    this.startSourcePath = (_startSourcePath && typeof(_startSourcePath) === 'string') ?
      _startSourcePath : DEMO_SRC_PATH
    assert((this._inputter && this._outputter) || (!this._inputter && !this.outputter))
    this.inputter = _inputter || getImmutableKey
    this.outputter = _outputter || setImmutableKey
    ensureDir(this.startSourcePath)
  }

  /**
   * Chain and return a (possibly asynchronous) call after the outputter,
   * also possibly asynchronous. 
   * @param outputCallResult the result calling outputter method, will have a `then`
   *        property if it's thenable / asynchronous.
   * @param callback method, possibly asynchronous, which accepts as input the
   *        return value of the outputter method call (`outputCallResult`) 
   */
  awaitOutputter(outputCallResult, afterOutput) {
    if (outputCallResult.then) {
      return outputCallResult.then(afterOutput) 
    } else {
      return afterOutput(outputCallResult)
    }
  }

  /**
   * Format the output from `solc` compiler into an Immutable {Map}
   */
  getCompileOutputFromSolc(solcOutputContracts, requestedInputs, existingOutputs) {
    const requestedOutputs = Map(solcOutputContracts).filter(
      (contract, contractLongName) => {
        const contractName = path.basename(contractLongName).split(':')[1]
        return requestedInputs.has(contractName)
      })
      .map((contract, contractLongName) => {
        const contractName = path.basename(contractLongName).split(':')[1]
        return {
          name: contractName,
          ...contract
        }
      })

    const tuples = List(requestedOutputs.values()).map((contract) => {
           
      const now = new Date() 
      const inputHash = requestedInputs.get(contract.name).get('inputHash') 
      const output = Map({
        type       : 'compile',
        name       : contract.name,
        code       : contract.bytecode,
        abi        : fromJS(JSON.parse(contract.interface)),
        contentHash: keccak(JSON.stringify(contract)).toString('hex'),
        inputHash  : inputHash,
        timestamp  : now.getTime(),
        dateTime   : now.toUTCString(),
      })
      // In some other place, the abiString is useful as a web output
      //const abiString = `abi${contract.name} = ${JSON.stringify(output['abi'], null, 2)}`
      const compileKey = `${COMPILES_DIR}/${contract.name}`
      if (existingOutputs.has(contract.name) &&
          existingOutputs.get(contract.name).get('inputHash') === inputHash) {
        LOGGER.warn(`${contract.name} is up-to-date with hash ${inputHash}, not overwriting.`)
        return [contract.name, existingOutputs.get(contract.name)]
      } else {
        return this.awaitOutputter(
          this.outputter(compileKey, output, true),
          () => { return [ contract.name, output ] }
        )
      }
    })
    return Promise.all(tuples).then((pairs) => { return Map(tuples) })
  }
  
  /**
   * Reformat a sourceMap for solc where keys are Solidity filenames
   * and values are the Solidity source files themselves.
   * @param inputsToBuild an Immutable {Map} with members `filename` for the
   *        original Solidity filename and `source` is the original Solidity source text.
   *        the key does not matter.
   * @return a sourceMap suitable for solc
   */
  getSourceMapForSolc(inputsToBuild) {
    return new Map(List(inputsToBuild.values()).map((val) => {
      const fn = val.get('filename')
      assert(val.get('source'), `${fn} contains null source`)
      return [ val.get('filename'), val.get('source') ]
    })) 
  } 
 
 /**
  * Traverse solidity source files from disk and build requested inputs, and a
  * solidity findImports callback function.
  * @param { source } the filename of the requested source file input to compile, could be empty for compile all files found
  * @return { findImports } a callback for solc to resolve import statements
  * @return { requestedInputs } an Immutable {Map} of filenames as keys and source file contents as values
  */ 
  getRequestedInputsFromDisk(source) {
    const allInputFiles = []
    const inputs = {}
    
    // Filter out empty paths
    const queue = Set(
      [ this.startSourcePath, ZEPPELIN_SRC_PATH ]
    ).filter((x) => x).toJS()

    traverseDirs(
      queue,
      (fnParts) => { return ((fnParts.length > 1) && !fnParts[1].startsWith('sol')) },
      function(source, f) {
        allInputFiles.push(path.basename(f))
        let paths = f.split(path.sep)
        const keys = []
        // This is a hack to push all suffixes of a contract path
        // since it's not clear which one solcjs will request
        // in findImport below
        do {
          keys.push(paths.join(path.sep))
          if (paths.length <= 1) { break }
          paths = paths.slice(-(paths.length - 1))
        } while(true)
        const sourceObj = {source: source, inputHash: keccak(source).toString('hex')}
        keys.forEach((key) => {
          if (inputs[key]) { LOGGER.warn(`Replacing import ${key} with ${f}`) }
          inputs[key] = sourceObj
        })
      }
    )
    
    if (!allInputFiles || allInputFiles.length == 0) {
      LOGGER.warn("No source files found.")
    }

    function findImports (path) {
      assert(inputs[path])
      return { contents: inputs[path].source }
    }

    // Filter out . and ..
    const inputFiles = (source && source.length > 2) ?
      List([path.basename(source)]) : List(allInputFiles)
    
    // Reformat keys to strip filename extensions, but keep the original filename as member
    const requestedInputs = new Map(inputFiles.map((name) => {
      const value = new Map(inputs[name]).set('filename', name) 
      assert(name.split('.')[1].startsWith('sol'))
      return [ name.split('.')[0], value ]
    }))

    return {
      requestedInputs : requestedInputs, 
      findImports     : findImports,
    }
  } 

  /**
   * @param source {string} name of source file to compile, including Solidity extension
   * @return compile output as an Immutable {Map}
   */
  compile(source) {
    // Open contracts installed by npm -E zeppelin-solidity
    // Open contracts from democracy
    
    const { requestedInputs, findImports } = this.getRequestedInputsFromDisk(source)

    const { contractOutputs: existingOutputs } = this.getContracts()
    const inputsToBuild = getInputsToBuild(requestedInputs, existingOutputs)

    const sourcesToBuild = this.getSourceMapForSolc(inputsToBuild)

    if (sourcesToBuild.count() === 0) {
      // Hooray, nothing to build. Return existing outputs as if we had built it.
      return existingOutputs.filter((val, key) => { return requestedInputs.has(key) })
    }
    LOGGER.debug('sourcesToBuild', sourcesToBuild)

    const outputs = solc.compile({sources: sourcesToBuild.toJS()}, 0, findImports)
    assert.ok(outputs.contracts, `Expected compile output for requested sources`)

    // Uncomment below to dump the output of solc compiler
    if (outputs.errors) {
      LOGGER.error(JSON.stringify(outputs.errors))
    }

    return this.getCompileOutputFromSolc(outputs.contracts, requestedInputs, existingOutputs)
  }

  getContracts() {
    const contractSources = []
    if (!fs.existsSync(this.startSourcePath)) {
      LOGGER.info(`Sources directory '${this.startSourcePath}' not found.`)
      return Map({
        contractSources: List(),
        contractOutputs: Map({}),
      })
    }
    traverseDirs(
      [this.startSourcePath], // start out by finding all contracts rooted in current directory
      (fnParts) => { return (fnParts.length > 1 && !fnParts[1].startsWith('sol')) },
      function(source, f) {
        const fn = List(f.split(path.sep)).last()
        const fb = path.basename(fn.split('.')[0])
        contractSources.push(fb)
        LOGGER.info(`Source ${fb}`)
      }
    )
    const contractOutputs = getImmutableKey(COMPILES_DIR, new Map({}))

    return {
      contractSources: List(contractSources),
      contractOutputs: contractOutputs
    }
  }

  /**
   * Asynchronously return a contract previously outputted at key `/compiles/`
   * @param contractName name of the compiled contract
   */
  async getContract(contractName) {
    const { contractOutputs } = this.getContracts(false)
    return contractOutputs.get(contractName)
  }

  async cleanContract(contract) {
    return this.outputter(`${COMPILES_DIR}/${contract}`, null)
  }

  async cleanAllCompiles() {
    return this.outputter(`${COMPILES_DIR}`, null)
  }

  async cleanCompile(compile) {
    return Promise.all(List(
      compile.map((compile, compileName) => {
        return this.cleanContract(compileName)
      }).values()).toJS()
    )
  }

}

/**
 * @return true if the given object is a compile output from a Compiler, otherwise false
 */
const isCompile = (_compile) => {
  return (_compile && Map.isMap(_compile) && _compile.count() > 0 &&
          _compile.reduce((prev, val) => {
    return prev && val.get('type') === 'compile'
  }, true))
}

/**
 * @return true if the given object is a compile output retrieved from db, otherwise false
 */
const isContract = (_contract) => {
  return (Map.isMap(_contract) && _contract.get('type') === 'compile')
}

module.exports = {
  Compiler         : Compiler,
  isCompile        : isCompile,
  isContract       : isContract,
}