# dcache 状态机


# 关于状态机：
- 状态：IDLE，ASKMEM，WRITE_DIRTY


- 读写命中
  P1：IDLE状态，将信号处理后传送给BRAM进行读出，TLB同时进行地址翻译
  P2：IDLE状态，根据读取结果判断命中成功，进行返回
- 读写不命中且不脏
  P1：IDLE状态，将信号处理后传送给BRAM进行读出，TLB同时进行地址翻译
  P2：IDLE状态，根据读取结果判断命中失败，不脏，开始向主存读
  P3：ASKMEM状态，找主存读，持续保持直到主存返回
  P4：IDLE状态，向cpu返回结果
- 读写不命中且脏
  P1：IDLE状态，将信号处理后传送给BRAM进行读出，TLB同时进行地址翻译
  P2：IDLE状态，根据读取结果判断命中失败，脏，开始向主存写
  P3：WRITE_DIRTY：持续保持向主存写的信号，直到写完成,开始向主存读
  P4：ASKMEM状态，找主存读，持续保持直到主存返回
  P4：IDLE状态，向cpu返回结果











  - 写后读问题的解决：自己写的BRAM比IP核的功能还是很有差距，最终通过添加信号修改代码，实现在自己的BRAM上操作还能避免写后读加一个时钟周期的问题