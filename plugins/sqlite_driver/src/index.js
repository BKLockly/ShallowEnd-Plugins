// sql.js（SQLite C 引擎的 asm.js 纯 JS 构建）薄包装：对齐 payload 的 sqlite 消费语义。
// payload 侧 dbDriverLoad 校验导出形状（typeof api.Database === 'function'），消费约定：
//   const conn = new Database(filePath);        —— 同步构造，path 为目标机上的 .db 文件
//   const rows = await conn.all(sql);           —— 行对象数组（fields 由 keys 推导）；多语句结果集按顺序拼接
//   const n    = await conn.run(sql);           —— 受影响行数；写后自动持久化写回源文件
//   conn.close();                               —— 同步，调用后连接可安全弃置
const fs = require('fs');
const initSqlJs = require('sql.js/dist/sql-asm.js');

// 引擎全局单例：asm.js 模块只需初始化一次，多连接复用
let enginePromise = null;
function engine() {
    if (!enginePromise) enginePromise = initSqlJs();
    return enginePromise;
}

// 整库全量进内存 + export 写回的形态下，超大文件会把宿主 Node 进程直接拖进 OOM
// （webshell 一并殉葬），构造时硬限而不是扫到一半崩。
const MAX_FILE_BYTES = 256 * 1024 * 1024;

class Database {
    constructor(pathOrBuffer) {
        if (Buffer.isBuffer(pathOrBuffer)) {
            this._path = null;
            this._bytes = pathOrBuffer;
        } else if (typeof pathOrBuffer === 'string' && pathOrBuffer.length > 0) {
            this._path = pathOrBuffer;
            this._bytes = fs.readFileSync(pathOrBuffer);
        } else {
            throw new Error('sqlite: Database(path | Buffer) required');
        }
        if (this._bytes.length > MAX_FILE_BYTES) {
            throw new Error(
                'sqlite: file too large for in-memory engine (' +
                    this._bytes.length + ' bytes, limit ' + MAX_FILE_BYTES + ')'
            );
        }
        this._db = null;
    }

    async _ensure() {
        if (!this._db) {
            const SQL = await engine();
            this._db = new SQL.Database(this._bytes);
        }
        return this._db;
    }

    async all(sql) {
        const db = await this._ensure();
        const results = db.exec(sql);
        // 多语句 SQL（如 SELECT a; SELECT b）产出多个结果集：
        // 每个结果集按自己的列名映射，所有行按结果集顺序拼接成一个数组
        const rows = [];
        for (const result of results) {
            if (!result.columns.length) continue; // 无列的结果集（DDL/写语句）跳过
            const columns = result.columns;
            for (const values of result.values) {
                const obj = {};
                for (let i = 0; i < columns.length; i++) obj[columns[i]] = values[i];
                rows.push(obj);
            }
        }
        return rows;
    }

    async run(sql) {
        const db = await this._ensure();
        db.exec(sql);
        const affected = db.getRowsModified();
        this._persist();
        return affected;
    }

    // 内存库 → 源文件全量写回（run 后调用）。非事务安全：目标机进程并发写同一
    // 文件会互相覆盖；渗透场景以查询为主，写回是"能写"而非"可靠写"。
    _persist() {
        if (!this._path || !this._db) return;
        fs.writeFileSync(this._path, Buffer.from(this._db.export()));
    }

    close() {
        if (this._db) {
            this._db.close();
            this._db = null;
        }
    }
}

module.exports = { Database: Database };
