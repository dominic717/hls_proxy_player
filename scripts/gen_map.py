#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_map.py —— 把你的 NAS 目录树，生成本播放器要用的 _map.txt 索引。

大白话：
  播放器连上你的 FTP 后，会去读根目录下的 _map.txt，靠它知道
  “有哪些剧、每集放在哪个文件夹”。这个脚本就是帮你自动生成这个文件的，
  你不用手写了。

用法（在电脑上跑，不是手机上）：
  python3 gen_map.py /Volumes/你的NAS/短剧
  这样会扫描 /Volumes/你的NAS/短剧 下的目录，生成 _map.txt 到当前目录。

  如果你的 FTP 根目录不是上面那个“短剧”文件夹，而是它的某一级父目录，
  加 --root-prefix 告诉脚本“相对 FTP 根的路径前缀”，例如：
  python3 gen_map.py /Volumes/NAS/短剧 --root-prefix 短剧

怎么判断“哪一个是剧”：
  一个文件夹里，只要含有形如 ep1、ep01、ep2_xxx 这样的子文件夹（数量 >=1），
  就当成一部剧。集数 = 这种子文件夹的个数。

生成的每行格式（播放器认这个）：
  剧名=集数=相对FTP根的路径=封面URL
  例： 我的剧=5=xiandai/drama_123=https://.../cover.jpg
  封面 URL 留空也行（播放器会用占位图）。
"""

import argparse
import os
import re

EP_RE = re.compile(r'^ep\d', re.IGNORECASE)          # ep1 / ep01 / ep2_xxx
DRAMA_RE = re.compile(r'drama_?\d+', re.IGNORECASE)  # drama_123 / drama123


def collect_dramas(root: str):
    """递归找出所有‘像剧’的文件夹，返回 (相对路径, 集数) 列表。"""
    results = []
    for dirpath, dirnames, _ in os.walk(root):
        # 这一层里，凡是名字像“第N集”的子文件夹，都算作这一部的集
        ep_dirs = [d for d in dirnames if EP_RE.match(d)]
        if len(ep_dirs) >= 1:
            rel = os.path.relpath(dirpath, root)
            rel = rel.replace(os.sep, '/')          # FTP 路径用 /
            if rel == '.':
                rel = ''
            results.append((rel, len(ep_dirs)))
    return results


def main():
    ap = argparse.ArgumentParser(description='生成 _map.txt 索引')
    ap.add_argument('nas_root', help='NAS 上短剧目录的本地挂载路径')
    ap.add_argument('--root-prefix', default='',
                    help='相对 FTP 根的路径前缀，例如 短剧')
    ap.add_argument('-o', '--out', default='_map.txt', help='输出文件')
    args = ap.parse_args()

    if not os.path.isdir(args.nas_root):
        raise SystemExit(f'目录不存在: {args.nas_root}')

    dramas = collect_dramas(args.nas_root)
    if not dramas:
        raise SystemExit('没找到任何“像剧”的文件夹（需要里面有 ep1、ep2… 这样的子文件夹）')

    prefix = args.root_prefix.strip().strip('/')
    lines = []
    for rel, ep_count in sorted(dramas, key=lambda x: x[0]):
        # 剧名：用文件夹名，顺便把 drama_123 这种前缀去掉，好看点
        name = os.path.basename(rel) if rel else 'root'
        name = DRAMA_RE.sub('', name).strip('_').strip() or name
        # 路径：前缀 + 相对路径
        path = f'{prefix}/{rel}' if (prefix and rel) else (prefix or rel)
        lines.append(f'{name}={ep_count}={path}=')

    with open(args.out, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')

    print(f'搞定：{len(lines)} 部剧 -> {args.out}')
    for ln in lines[:5]:
        print('  ', ln)
    if len(lines) > 5:
        print(f'  ... 共 {len(lines)} 部')


if __name__ == '__main__':
    main()
