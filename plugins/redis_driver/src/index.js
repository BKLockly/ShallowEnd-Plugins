// node-redis（官方 redis 客户端，纯 JS）原样 CJS 导出：payload 侧 dbDriverLoad 以
// new Function('module','exports','require') 加载，消费 api.createClient。
// 消费约定见 payload execSql redis 分支：createClient({socket:{host,port},password,
// database}) → await connect() → sendCommand([cmd, ...args]) → disconnect()。
module.exports = require('redis');
