// pg 作为 CJS 导出：payload 侧 dbDriverLoad 以
// new Function('module','exports','require') 加载，消费 api.Client
module.exports = require('pg');
